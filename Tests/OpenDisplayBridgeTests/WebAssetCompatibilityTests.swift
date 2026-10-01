import Foundation
import XCTest

@testable import OpenDisplayBridge

/// Guards the web assets against CSS and JS that only work on a modern browser.
///
/// ## Why this exists
///
/// The receiver's video element is styled `position: absolute; inset: 0` — the
/// `inset` shorthand. That shorthand shipped in **Safari 14.1**. On the iPad this
/// project exists for (iOS 12.5, Safari 12.1) the declaration is not ignored
/// loudly, it is simply not applied: the element ends up absolutely positioned
/// with `auto` offsets and no content-derived size, so it collapses to **0×0**.
///
/// The symptom was the worst kind. Everything about the pipeline was provably
/// healthy — 206 frames delivered, `readyState 4`, not paused, 528x360 decoded,
/// `currentTime` advancing in realtime — and the screen was black, because there
/// was nowhere to paint it. It took a layout measurement (`css=0x0`, and
/// `elementFromPoint` returning `BODY`) to tell "hidden" apart from "genuinely
/// black", and nothing short of that measurement would have found it.
///
/// This is trivially checkable and impossible to notice by reading, so it is
/// checked mechanically. The rule: **no browser-version-dependent CSS shorthand
/// in these assets**, because the target device is old enough that they do not
/// work and new enough that they look fine on the developer's machine.
final class WebAssetCompatibilityTests: XCTestCase {

    /// Reads an asset from the source tree.
    ///
    /// Deliberately not from a bundle. The `Web/` files are resources of the
    /// *executable* target, so they are not in the test bundle, and reaching into
    /// `OpenDisplayBridge_OpenDisplayBridge.bundle` would test a copy that can
    /// drift from the source. `#filePath` anchors on the repository, so this
    /// checks the bytes that actually get compiled and served.
    private func asset(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenDisplayBridgeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let url = root.appendingPathComponent("Sources/OpenDisplayBridge/Web/\(name)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "\(name) must exist at \(url.path)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// `inset` (Safari 14.1+), `gap` in flexbox (Safari 14.1+), `place-items`
    /// (Safari 14.1+), `:is()`/`:where()` (Safari 14+), and `aspect-ratio`
    /// (Safari 15+). All are silent no-ops on iOS 12, which is precisely the
    /// failure mode this guards against.
    private let modernOnlyShorthand = [
        "inset:", "aspect-ratio:", "place-items:", "place-content:",
    ]

    func testNoBrowserVersionDependentShorthandInCSS() throws {
        for name in ["index.html"] {
            let text = try asset(name)
            for token in modernOnlyShorthand {
                // Skip legitimate uses inside comments or property names that
                // merely contain the token as a substring.
                let occurrences = text.components(separatedBy: token).count - 1
                XCTAssertEqual(occurrences, 0,
                    "\(name) uses `\(token)`, which does not work on the target "
                    + "iOS 12.5 / Safari 12.1 receiver. Spell out the longhands "
                    + "(top/right/bottom/left) instead — a no-op declaration "
                    + "produces a collapsed element and no error.")
            }
        }
    }

    /// The same check for inline styles set from JavaScript, which is where the
    /// video element is actually styled.
    func testNoBrowserVersionDependentShorthandInInlineStyles() throws {
        let text = try asset("receiver.js")
        // Only look at style strings, so an unrelated identifier cannot trip it.
        for line in text.components(separatedBy: .newlines) where line.contains("cssText")
            || line.contains("style.css") || line.contains("style.width")
            || line.contains("style.height") {
            for token in modernOnlyShorthand where token == "inset:" {
                XCTAssertFalse(line.contains(token),
                    "inline style uses `\(token)`, unsupported on Safari 12.1: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// The video element must actually be given a size. This is the specific
    /// regression: the element plays, decodes, and reports a sensible
    /// `videoWidth`, yet is 0×0 on screen.
    func testVideoElementIsExplicitlySized() throws {
        let text = try asset("receiver.js")
        let styled = try XCTUnwrap(
            text.components(separatedBy: "rtcEl.style.cssText = ").dropFirst().first,
            "receiver.js must style rtcEl")
        for required in ["position:absolute", "width:100%", "height:100%",
                         "top:0", "left:0"] {
            XCTAssertTrue(styled.contains(required),
                "rtcEl's inline style must include `\(required)`; got: \(styled.prefix(200))")
        }
    }

    /// Both surfaces need real geometry, or one of the two video paths is
    /// invisible. The canvas carries passthrough, the video element carries
    /// WebRTC, and both were `inset`-based.
    func testBothSurfacesHaveLayout() throws {
        let html = try asset("index.html")
        XCTAssertTrue(html.contains("#stage"), "index.html must define #stage")
        XCTAssertTrue(html.contains("#screen"), "index.html must define #screen")
        // The stage is the positioned ancestor for both surfaces.
        XCTAssertTrue(html.contains("position: absolute; top: 0; right: 0; bottom: 0; left: 0;"),
            "#stage must be pinned with explicit offsets, not the `inset` shorthand")
    }

    /// APIs that do not exist on iOS 12 must never be called unguarded.
    ///
    /// The fullscreen button called `document.documentElement.requestFullscreen`
    /// directly. That is undefined on Safari 12, so every tap threw a TypeError —
    /// which the receiver's own error handler reported faithfully as
    /// `requestFullscreen is not a function`, and that report is how it was
    /// found. iOS Safari only has `webkitRequestFullscreen`, and for a video
    /// element `webkitEnterFullscreen`.
    func testFullscreenHasPrefixedFallbacks() throws {
        let text = try asset("receiver.js")
        XCTAssertTrue(text.contains("webkitRequestFullscreen"),
            "requestFullscreen needs a webkitRequestFullscreen fallback for iOS 12")
        XCTAssertTrue(text.contains("webkitEnterFullscreen"),
            "fullscreen for a <video> on iOS needs webkitEnterFullscreen")
        XCTAssertTrue(text.contains("webkitExitFullscreen"),
            "exiting fullscreen on iOS needs webkitExitFullscreen")

        // No line may call an unprefixed fullscreen method outright. Lines that
        // mention `webkit` or are part of an `a || b` chain are the fallbacks.
        //
        // Comments are stripped first: this file's own comment quotes the broken
        // call verbatim, and a scan that reads its own documentation fails on it.
        for raw in text.components(separatedBy: .newlines) {
            let code: String
            if let range = raw.range(of: "//") {
                code = String(raw[raw.startIndex..<range.lowerBound])
            } else {
                code = raw
            }
            guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            for api in ["requestFullscreen", "exitFullscreen"] {
                guard code.contains(api) else { continue }
                let bare = code.contains("." + api)
                    && !code.contains("webkit")
                    && !code.contains("||")
                    && !code.contains("const ")
                XCTAssertFalse(bare,
                    "unguarded unprefixed \(api): " + code.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    /// The settings panel's controls must exist and be wired, because a missing
    /// id fails silently: the panel opens to an empty-looking sheet and there is
    /// no error to notice.
    func testSettingsPanelIsPresent() throws {
        let html = try asset("index.html")
        for id in ["gear-btn", "settings", "set-debug", "set-res", "set-res-val",
                   "set-refresh", "set-close"] {
            XCTAssertTrue(html.contains("id=\"" + id + "\""),
                "index.html must define #" + id + " \u{2014} a missing id fails silently")
        }
        // Debug must be off by default. The overlay is how every bug in this
        // project was found, which is exactly why it should not be covering a
        // quarter of a tablet screen for someone who just wants a display.
        let js = try asset("receiver.js")
        XCTAssertTrue(js.contains("debug: false"),
            "settings must default to debug off")
        XCTAssertTrue(js.contains("statsEl.style.display = S.showDebug ? 'block' : 'none'"),
            "the debug toggle must actually control the overlay's visibility")
    }

    /// The multiplier has to feed the hello's caps, and the caps must stay even:
    /// H.264 4:2:0 rejects odd dimensions, and 0.75x of 1080 is a trap if the
    /// rounding is done on the product rather than per axis.
    func testResolutionMultiplierFeedsHelloAndStaysEven() throws {
        let js = try asset("receiver.js")
        XCTAssertTrue(js.contains("maxEncodeWide: maxW, maxEncodeHigh: maxH"),
            "the hello must send the computed caps")
        XCTAssertTrue(js.contains("/ 2) * 2"),
            "caps must be rounded to even, per axis")

        // Mirror the JS and check every offered multiplier yields even, sane
        // dimensions on both paths.
        let bases = [(1920, 1080), (640, 360)]
        let mults = [1.0, 2.0, 3.0, 4.0]
        for base in bases {
            for mul in mults {
                let w = Int((Double(base.0) * mul / 2).rounded()) * 2
                let h = Int((Double(base.1) * mul / 2).rounded()) * 2
                XCTAssertEqual(w % 2, 0, "width \(w) must be even (\(base.0) x \(mul))")
                XCTAssertEqual(h % 2, 0, "height \(h) must be even (\(base.1) x \(mul))")
                XCTAssertGreaterThan(w, 0)
                XCTAssertGreaterThan(h, 0)
            }
        }
    }

    /// The offered multipliers, the default, and the panel must agree.
    ///
    /// These are three separate places — the JS whitelist, the stored default,
    /// and the buttons in the HTML — and a mismatch fails quietly. A value in the
    /// whitelist with no button is unselectable; a button absent from the
    /// whitelist is rejected by the click handler and does nothing when tapped,
    /// which looks exactly like a dead control.
    func testResolutionOptionsAndDefaultAgree() throws {
        let js = try asset("receiver.js")
        let html = try asset("index.html")

        let list = try XCTUnwrap(js.range(of: "const RES_MULS = ["))
            .lowerBound
        let line = js[list...].prefix(while: { $0 != "\n" })
        XCTAssertTrue(line.contains("'1', '2', '3', '4'"),
            "the offered multipliers must be 1x-4x, got: \(line)")

        XCTAssertTrue(js.contains("const DEFAULT_RES_MUL = '2';"),
            "2x is the default: 1x is 640x360 upscaled on the iPad, which is "
            + "visibly soft, and the iPad is the path this project exists for")

        // Every button the panel offers must be in the whitelist, and every
        // whitelist entry must have a button. `data-m="1"` is unambiguous here —
        // the only other `data-m` on the page is the debug toggle's boolean.
        var buttons = Set<String>()
        var rest = html[...]
        while let open = rest.range(of: "data-m=\"") {
            let after = open.upperBound
            let close = after < html.endIndex
                ? html[after...].firstIndex(of: "\"")
                : nil
            guard let close, let value = try? String(html[after..<close]) else { break }
            buttons.insert(value)
            rest = html[close...]
        }
        XCTAssertEqual(buttons, ["1", "2", "3", "4"],
            "the panel must offer exactly 1x, 2x, 3x and 4x, got \(buttons)")

        // "Auto" used to be the label for 1x, because the per-path base is a
        // tuned default. It was the same number wearing a second name —
        // capsWidth() is base x resMul — so the label only obscured the fact
        // that 1x resolves to a real, reportable resolution.
        XCTAssertFalse(line.contains("'0.5'") || line.contains("'0.75'") || line.contains("'1.5'"),
            "half steps are gone; a stored one must fall back rather than apply")
        XCTAssertFalse(js.contains("? 'auto'"), "no auto/1x special case remains")
        XCTAssertFalse(html.contains(">Auto<"), "no Auto button remains")

        // A stored value from an older build must not survive as a scale the
        // panel cannot show. Otherwise the readout reports a resolution nobody
        // chose and no button is highlighted.
        XCTAssertTrue(js.contains("if (RES_MULS.indexOf(String(s.resMul)) < 0)"),
            "loadSettings must reject a stored multiplier that is no longer offered")
    }

    /// The controls must not be nested inside the touch surface.
    ///
    /// `#stage` is the input surface: it calls `preventDefault()` on pointerdown
    /// and takes pointer capture, because a drag on the screen is meant to become
    /// a touch/scroll event, not a page gesture.
    ///
    /// When the gear button and settings panel lived inside it, every tap was
    /// swallowed. A `pointerdown` on a button bubbles to the stage, and a pointerup
    /// landing even a pixel off the button makes the browser fire `click` on the
    /// nearest common ancestor — the stage — so the button never received it.
    /// The UI appeared to react and then did nothing, on every tap, with no error
    /// anywhere. Guarding the stage handlers with a `closest()` check is not
    /// sufficient on its own: the click target is still wrong.
    ///
    /// So the fix is structural. They are siblings of the stage, and nothing in
    /// the input path can intercept them.
    func testControlsAreNotNestedInsideTheTouchSurface() throws {
        let html = try asset("index.html")
        let stageStart = try XCTUnwrap(html.range(of: "id=\"stage\"")).lowerBound
        // The stage's own children run to the first closing tag at its indent
        // level; find the `</div>` that closes it.
        let stageEnd = try XCTUnwrap(
            html.range(of: "</div>", range: stageStart..<html.endIndex),
            "the stage must be a closed element"
        ).lowerBound
        let insideStage = String(html[stageStart..<stageEnd])

        for id in ["gear-btn", "fs-btn", "settings", "stats", "status-banner"] {
            XCTAssertFalse(insideStage.contains("id=\"" + id + "\""),
                "#" + id + " must be a sibling of #stage, not a child of the "
                + "input surface, or taps on it get swallowed")
        }
        // The stage should still hold the surfaces a drag acts on.
        XCTAssertTrue(insideStage.contains("id=\"screen\""), "#screen belongs in the stage")
        XCTAssertTrue(insideStage.contains("id=\"cursor\""), "#cursor belongs in the stage")
    }

    /// Input coordinates must be measured against the surface that is on screen.
    ///
    /// This has now bitten three times, always the same way and always silently.
    /// There are two picture elements: the canvas, used by the WebCodecs path,
    /// and the `<video>`, used by the WebRTC path. Whichever is not in use is
    /// hidden with `display: none`, and a `display: none` element has an all-zero
    /// `getBoundingClientRect()` — so dividing a client coordinate by its width
    /// yields `Infinity`, which `JSON.stringify` writes as `null`. The sender
    /// receives a touch with no coordinates and ignores it. No error is raised on
    /// either side, and the symptom is indistinguishable from "the sender does not
    /// implement input injection".
    ///
    /// The cursor hit it first (a 0×0 rect placed the cursor at the origin and
    /// made it look like rendering had stopped), then the wheel handler (every
    /// scroll delta scaled to nothing), then touch itself. Each was fixed by
    /// hand-inlining the same ternary, which is why a fourth was possible: at
    /// every new site someone has to remember. So the choice now lives in one
    /// function, and this test holds it to that.
    func testInputCoordinatesUseTheVisibleSurface() throws {
        let js = try asset("receiver.js")

        // The helper exists and picks the video element when WebRTC is live.
        XCTAssertTrue(js.contains("function activeSurface()"),
            "the visible-surface choice must live in one named helper")
        XCTAssertTrue(js.contains("rtcEl.srcObject) ? rtcEl : canvas"),
            "activeSurface() must return the <video> on the WebRTC path and the "
            + "canvas otherwise")

        // No site may measure against the canvas directly. The helper's own body
        // is the one legitimate reference, and it does not call
        // getBoundingClientRect, so any occurrence here is a real call site.
        for (n, line) in js.split(separator: "\n").enumerated()
        where line.contains("canvas.getBoundingClientRect") {
            XCTFail("receiver.js:\(n + 1) measures against the canvas directly: "
                + "use activeSurface() — the canvas is display:none on the WebRTC "
                + "path and its rect is 0x0, which sends null coordinates")
        }

        // Every measured surface goes through the helper.
        let measured = js.split(separator: "\n")
            .filter { $0.contains("getBoundingClientRect") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // The diagnostics measure the video element deliberately, to report
        // whether it is actually visible; that is the one legitimate exception.
        let exceptions = ["const rect = rtcEl.getBoundingClientRect();"]
        for line in measured {
            let viaHelper = line.contains("activeSurface()")
            let isException = exceptions.contains(line)
            XCTAssertTrue(viaHelper || isException,
                "measures without activeSurface(): \(line)")
        }
    }

    /// A zero-width rect must not produce a coordinate.
    ///
    /// Guards the second half of the bug: even routed through the right element,
    /// a surface that is hidden or not yet laid out yields a 0×0 rect, and
    /// dividing by it again produces `Infinity`. Returning null and dropping the
    /// event is the honest response — the sender ignores those anyway, and
    /// anything outside 0..1 would have it act on a position nobody pointed at.
    func testZeroSizedSurfaceDropsTouchInsteadOfSendingNulls() throws {
        let js = try asset("receiver.js")
        XCTAssertTrue(js.contains("if (!r.width || !r.height) return null;"),
            "normPoint must refuse to divide by a zero-width rect")
        XCTAssertTrue(js.contains("if (!p) return;"),
            "sendTouch must drop the event when normPoint has no answer")
        XCTAssertTrue(js.contains("if (p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1) return;"),
            "sendTouch must drop off-picture coordinates rather than send them")
    }

    /// A dropped WebSocket must not leave a dead peer connection behind.
    ///
    /// `startWebRTC` opens with `if (S.rtc) return;`, so whatever `S.rtc` holds
    /// when the socket dies decides whether the *next* session can ever
    /// negotiate. `teardown()` used to clear the timers, the decoder and the
    /// clock but not `S.rtc`, so on reconnect `onopen` called `startWebRTC`, it
    /// returned on that guard, and no `rtcOffer` was ever sent again.
    ///
    /// The result was the worst possible failure for this project: a perfectly
    /// healthy WebSocket, a "connected" banner, and a black screen forever —
    /// recoverable only by reloading the page. It hits precisely the device that
    /// takes the WebRTC path (an old iPad with no WebCodecs), which is also the
    /// one most likely to drop its connection by sleeping or roaming off the
    /// Wi-Fi.
    ///
    /// Checked by shape, because the state machine is in JavaScript and the rest
    /// of this file checks invariants rather than executing the page: every
    /// session-scoped field `startWebRTC` depends on must be cleared by
    /// `teardown`, or a reconnect inherits the previous session's state.
    func testTearingDownTheSocketClearsThePeerConnection() throws {
        let js = try asset("receiver.js")

        // Isolate teardown's body, so the checks below cannot be satisfied by
        // the same field names appearing elsewhere in the file.
        let body = try XCTUnwrap(js.range(of: "function teardown() {")
            .map { start -> String in
                let rest = js[start.upperBound...]
                guard let end = rest.range(of: "\n}") else { return "" }
                return String(rest[..<end.lowerBound])
            },
            "teardown() must exist")

        XCTAssertTrue(body.contains("S.rtc = null;"),
            "teardown must clear S.rtc — startWebRTC bails on `if (S.rtc) return;`, "
            + "so a surviving reference blocks renegotiation on every reconnect "
            + "and the receiver shows a black screen until a manual reload")
        XCTAssertTrue(body.contains("S.rtc.close()"),
            "teardown must close the peer connection it is dropping, or the "
            + "browser keeps a live connection to a bridge that has forgotten it")

        // The delta counters below are only correct when they start from zero.
        // `startWebRTC` resets them, but it is the thing being gated by the
        // `S.rtc` check, so they cannot be relied on to run.
        for field in ["S.rtcPrevFrames = 0;", "S.rtcPrevBytes = 0;",
                      "S.displayedFrames = 0;"] {
            XCTAssertTrue(body.contains(field),
                "teardown must reset \(field) — otherwise a reconnect's first "
                + "getStats() reports the previous session's totals as one "
                + "second's rate")
        }

        // Reported per session, so a stale value misdescribes the current one.
        // "mode webRTC" on a session the bridge chose passthrough is the kind of
        // wrong-but-plausible line that costs an hour of debugging.
        for field in ["S.bridgeMode = null;", "S.bridgeDecoder = null;",
                      "S.senderConnected = null;"] {
            XCTAssertTrue(body.contains(field),
                "teardown must reset \(field) — bridgeStatus is per session, so a "
                + "stale value reports the previous session's mode and sender state")
        }
    }
}
