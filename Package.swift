// swift-tools-version:5.9
import Foundation
import PackageDescription

// MARK: - OpenH264 (software H.264 decoder)
//
// Why a hand-built copy rather than only a Homebrew dependency: OpenH264 has no
// SwiftPM distribution and Cisco publishes no prebuilt macOS binaries, so the
// convenient source is the homebrew-core bottle. That bottle is built against
// whatever macOS Homebrew's CI runs, and 2.6.0 currently declares
// LC_BUILD_VERSION minos 26.0 — so anything linking it only runs on macOS 26,
// whatever this package's deployment target says. `tools/build-openh264.sh`
// builds the same source with MACOS_DEPLOYMENT_TARGET=13.0 and installs it to
// `vendor/openh264`, which is listed first below, so a normal build is portable
// again. Homebrew stays as the fallback, and the explicit env var still wins.
//
// Why it is needed at all: the software decoder is what makes the WebRTC
// fallback work on a machine where VideoToolbox will not decode. See
// WEBRTC_PLAN.md.
//
// Set OD_NO_OPENH264=1 to build without it. The app still compiles and the
// WebCodecs passthrough path still works; only the WebRTC transcode path
// reports itself unavailable, because there is no other decoder to fall back
// to.
let openH264Disabled = ProcessInfo.processInfo.environment["OD_NO_OPENH264"] == "1"

let openH264Prefixes: [String] = {
    guard !openH264Disabled else { return [] }
    let candidates = [
        ProcessInfo.processInfo.environment["OD_OPENH264_PREFIX"],
        // Built by tools/build-openh264.sh. First, so a release build is
        // portable; a Homebrew bottle would drag minos 26 in with it.
        "vendor/openh264",
        // Homebrew's versioned symlink is the stable path; it survives upgrades.
        "/opt/homebrew/opt/openh264",   // Apple silicon
        "/usr/local/opt/openh264",      // Intel
    ].compactMap { $0 }

    // Every entry is made absolute before use, and the result is the single
    // source of truth for the -I, the -L and the rpath.
    //
    // A relative prefix appears to work and then does not, differently in each
    // place: the existence check happens to resolve against the package root, so
    // the prefix looks valid; the header search then fails, because clang does
    // not resolve -I against the package root the way the check did. And even if
    // that were fixed, an rpath is resolved by dyld at LOAD time relative to the
    // binary, so a relative one would be recorded verbatim and never resolve —
    // the app would then fail to launch with a missing-library error naming no
    // path it actually tried.
    let cwd = FileManager.default.currentDirectoryPath
    return candidates.map { $0.hasPrefix("/") ? $0 : "\(cwd)/\($0)" }
        .filter { FileManager.default.fileExists(atPath: "\($0)/include/wels/codec_api.h") }
}()

let openH264LinkerSettings: [LinkerSetting] = {
    guard let prefix = openH264Prefixes.first else { return [] }
    // `prefix` is already absolute — see openH264Prefixes, which absolutises
    // once so the -I, the -L and the rpath cannot disagree.
    return [
        // `-rpath` is absolute so the dylib is found without DYLD_LIBRARY_PATH.
        // The other rpaths in this file are for the app bundle; this one is for
        // a library that lives outside it.
        //
        // tools/make-app.sh strips this again for a real bundle, because the
        // bundle carries its own copy and the build machine's path should not be
        // baked into something that gets shipped.
        .unsafeFlags([
            "-L\(prefix)/lib", "-lopenh264",
            "-Xlinker", "-rpath", "-Xlinker", "\(prefix)/lib",
        ])
    ]
}()

var targets: [Target] = []

if openH264Prefixes.isEmpty {
    FileHandle.standardError.write(Data("""
    warning: OpenH264 not found, so the WebRTC transcode path will be \
    unavailable. Build it with `tools/build-openh264.sh` (portable, and what a \
    release should use), or `brew install openh264` (faster, but its bottle \
    requires macOS 26), or set OD_OPENH264_PREFIX to a prefix containing \
    include/wels/codec_api.h.

    """.utf8))
}

if !openH264Prefixes.isEmpty {
    targets.append(
        .target(
            name: "COpenH264",
            path: "Sources/COpenH264",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                // wels/*.h is only needed to compile od_h264.cpp. It is
                // deliberately not exposed through the module: Swift sees only
                // od_h264.h, so the C++ types never leak across the boundary.
                .unsafeFlags(["-I\(openH264Prefixes[0])/include"]),
            ],
            linkerSettings: openH264LinkerSettings
        )
    )
}

targets += [
    .executableTarget(
        name: "OpenDisplayBridge",
        dependencies: [
            .product(name: "WebRTC", package: "WebRTC")
        ] + (openH264Prefixes.isEmpty ? [] : ["COpenH264"]),
        path: "Sources/OpenDisplayBridge",
        resources: [.process("Web")],
        linkerSettings: [
            // SwiftPM resolves the WebRTC xcframework under .build/artifacts
            // and links against it, but never copies it where the product
            // can load it, so the app dies at launch with
            // "dyld: Library not loaded: @rpath/WebRTC.framework/WebRTC".
            // tools/stage-frameworks.sh copies the macOS slice next to the
            // built product for development; tools/make-app.sh puts it in
            // Contents/Frameworks for a real bundle.
            //
            // The ../Frameworks form is the one an .app actually needs:
            // @executable_path alone resolves to Contents/MacOS/Frameworks,
            // which is not where an app keeps frameworks.
            //
            // unsafeFlags are fine here: this is a root package, never a
            // dependency of another.
            .unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "@loader_path/Frameworks",
            ])
        ]
    ),
    .testTarget(
        name: "OpenDisplayBridgeTests",
        dependencies: ["OpenDisplayBridge"] + (openH264Prefixes.isEmpty ? [] : ["COpenH264"]),
        path: "Tests/OpenDisplayBridgeTests",
        // A short capture from the real OpenDisplay.app sender, replayed by
        // RealSenderStreamTests. Synthetic H.264 from OpenH264's own encoder
        // proves the plumbing but not the plumbing *against a real sender*, and
        // the two bugs that cost the most time here — a mid-stream session
        // teardown and a lock-ordering deadlock — only reproduced on the real
        // stream.
        resources: [.copy("Fixtures")]
    ),
]

let package = Package(
    name: "OpenDisplayBridge",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Prebuilt WebRTC (BSD-3-Clause, upstream Google WebRTC) for the
        // WebRTC fallback path — see WEBRTC_PLAN.md. A browser cannot decode
        // H.264 below iOS 16.4 (no WebCodecs) or below iOS 13 (no MSE), so
        // WebRTC (iOS 11+) is the only in-browser route for old iPads.
        .package(url: "https://github.com/stasel/WebRTC.git", from: "153.0.0")
    ],
    targets: targets
)
