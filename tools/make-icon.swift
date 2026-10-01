#!/usr/bin/swift
// Generate AppIcon.icns for the app bundle.
//
//   tools/make-icon.swift [output.icns]
//
// Why a generator rather than a checked-in binary: an .icns is a container of
// pre-rendered PNGs, so there is nothing to review in a diff and no way to tell
// what changed. The drawing is ~80 lines of CoreGraphics and stays readable.
//
// The motif is the thing the project actually does: one screen, mirrored to a
// second, smaller one. A single display would read as "a Mac app"; the pair
// reads as "this Mac, over there", which is the whole point.
//
// Geometry follows Apple's macOS icon grid: the squircle occupies 824/1024 of
// the canvas (100pt margin per side) with a 22.37% corner radius, so the icon
// sits correctly in the Dock and in Finder next to system icons.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

let canvas = 1024
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/AppIcon.icns"

// The app's own accent, from index.html, so the icon and the UI agree.
let accentTop = NSColor(srgbRed: 0.16, green: 0.62, blue: 1.00, alpha: 1)
let accentBottom = NSColor(srgbRed: 0.04, green: 0.24, blue: 0.62, alpha: 1)

/// Draws the whole icon at `size` and returns PNG bytes.
func renderPNG(size: Int) -> Data? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    // Work in a 1024-unit space regardless of output size, so every shape below
    // is written once and scales cleanly to 16pt.
    let s = CGFloat(size) / CGFloat(canvas)
    ctx.scaleBy(x: s, y: s)

    // ---- background squircle ----
    let inset: CGFloat = 100
    let side = CGFloat(canvas) - inset * 2
    let bg = CGRect(x: inset, y: inset, width: side, height: side)
    let squircle = CGPath(roundedRect: bg, cornerWidth: side * 0.2237,
                          cornerHeight: side * 0.2237, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [accentTop.cgColor, accentBottom.cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: canvas),
                           end: CGPoint(x: 0, y: 0),
                           options: [])
    ctx.restoreGState()

    // ---- the two displays ----
    // The motif is one screen mirrored to another. Everything is positioned from
    // the squircle's centre (512,512) rather than from hand-picked coordinates,
    // because the first version placed the pair by eye and it came out sitting
    // low and left with dead space in the top corner — the kind of imbalance
    // that reads as "unfinished" without being obviously wrong.
    //
    // CoreGraphics puts the origin at the bottom-left with y increasing UPWARD,
    // so a monitor's stand must have a SMALLER y than its screen. The first
    // attempt had that backwards and rendered the monitor standing on its head.

    // Primary: a desktop display with a stand. The screen sits slightly above
    // centre so the stand does not drag the group downward.
    let screen = CGRect(x: 225, y: 438, width: 340, height: 212)
    let stand = CGRect(x: 378, y: 394, width: 34, height: 44)
    let base = CGRect(x: 330, y: 372, width: 130, height: 22)

    // Secondary: a portrait tablet, faintly translucent so the pair reads as two
    // devices at different depths rather than one mass.
    let tablet = CGRect(x: 607, y: 361, width: 196, height: 300)

    func fill(_ r: CGRect, radius: CGFloat, _ color: NSColor) {
        ctx.setFillColor(color.cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius,
                           cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }
    func fill(_ r: CGRect, radius: CGFloat, alpha: CGFloat) {
        fill(r, radius: radius, NSColor(white: 1, alpha: alpha))
    }

    // A lit screen, not a blank card: a white body with a tinted interior. The
    // tint has to be an actual colour — drawing it as translucent white over a
    // white body is white on white, which is what the first two attempts did and
    // why the display read as a featureless rounded rectangle.
    let litScreen = NSColor(srgbRed: 0.80, green: 0.89, blue: 1.00, alpha: 1)
    let dimScreen = NSColor(srgbRed: 0.63, green: 0.76, blue: 0.94, alpha: 1)

    func display(_ body: CGRect, bodyRadius: CGFloat, bodyAlpha: CGFloat,
                 bezel: CGFloat, interior: NSColor) {
        fill(body, radius: bodyRadius, alpha: bodyAlpha)
        fill(body.insetBy(dx: bezel, dy: bezel),
             radius: max(4, bodyRadius - bezel * 0.7), interior)
    }

    display(tablet, bodyRadius: 28, bodyAlpha: 0.72, bezel: 18, interior: dimScreen)
    fill(base, radius: 11, alpha: 1)
    fill(stand, radius: 8, alpha: 1)
    display(screen, bodyRadius: 24, bodyAlpha: 1, bezel: 22, interior: litScreen)

    guard let image = ctx.makeImage() else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString,
                                                     1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

guard let rep = NSBitmapImageRep(data: renderPNG(size: canvas) ?? Data()) else {
    FileHandle.standardError.write("icon: render failed\n".data(using: .utf8)!)
    exit(1)
}

// Also drop a 1024 PNG next to the .icns, for the README and for anyone who
// wants the artwork without the container.
try? rep.representation(using: .png, properties: [:])?
    .write(to: URL(fileURLWithPath: (outputPath as NSString).deletingLastPathComponent
                   + "/AppIcon-1024.png"))

// ---- .iconset -> .icns ----
// iconutil needs every one of these exact names, or it refuses the set.
let iconset = NSTemporaryDirectory() + "/AppIcon-\(UUID().uuidString).iconset"
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: iconset) }

let variants: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for v in variants {
    guard let png = renderPNG(size: v.px),
          let r = NSBitmapImageRep(data: png),
          let data = r.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("icon: \(v.name) failed\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: URL(fileURLWithPath: "\(iconset)/\(v.name).png"))
}

try? FileManager.default.createDirectory(atPath: (outputPath as NSString).deletingLastPathComponent,
                                         withIntermediateDirectories: true)
// `try?` not `try`: on a first run the file is not there yet, and removeItem
// throws rather than returning false.
try? FileManager.default.removeItem(atPath: outputPath)

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset, "-o", outputPath]
try proc.run()
proc.waitUntilExit()

guard proc.terminationStatus == 0 else {
    FileHandle.standardError.write("icon: iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(outputPath)")
