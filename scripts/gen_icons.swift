#!/usr/bin/env swift
// Regenerates every app icon + logo PNG from the vector master `assets/logo.svg`.
//
//   swift scripts/gen_icons.swift        (run from the repo root)
//
// Outputs:
//   macos/Assets.xcassets/AppIcon.appiconset/icon_{16..1024}.png
//       RELEASE — logo on a white macOS squircle.
//   macos/Assets.xcassets/AppIconDebug.appiconset/icon_{16..1024}.png
//       DEBUG — blueprint blue with grid + construction lines, logo drawn as a
//       white schematic. The background IS the build marker (no DEV badge).
//   macos/Assets.xcassets/AppIconImage.imageset/…  (About window / alert logo)
//   assets/logo.png                                (README header, raw glyph)
import AppKit

let fm = FileManager.default
let repo = fm.currentDirectoryPath
guard fm.fileExists(atPath: repo + "/assets/logo.svg") else {
    fatalError("run from the repo root (assets/logo.svg not found)")
}
guard let logoSVG = NSImage(contentsOfFile: repo + "/assets/logo.svg") else {
    fatalError("cannot load assets/logo.svg")
}

// ── Drawing helpers ──────────────────────────────────────────────────────

func renderPNG(size: Int, to path: String, draw: (CGFloat) -> Void) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
    print("  \(path) (\(size)px)")
}

/// Apple's macOS icon grid: an 824/1024 rounded square centered on the canvas.
func squircle(_ s: CGFloat) -> NSBezierPath {
    let inset = s * 100.0 / 1024.0
    let radius = s * 185.0 / 1024.0
    return NSBezierPath(
        roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
        xRadius: radius, yRadius: radius)
}

/// The logo rendered at `box` px, optionally tinted to a flat color
/// (tint keeps the alpha silhouette — used for the blueprint schematic look).
func logoImage(box: CGFloat, tint: NSColor?) -> NSImage {
    let img = NSImage(size: NSSize(width: box, height: box))
    img.lockFocus()
    logoSVG.draw(in: NSRect(x: 0, y: 0, width: box, height: box))
    if let tint {
        tint.set()
        NSRect(x: 0, y: 0, width: box, height: box).fill(using: .sourceAtop)
    }
    img.unlockFocus()
    return img
}

func drawLogo(canvas s: CGFloat, scale: CGFloat, tint: NSColor? = nil) {
    let box = s * scale
    logoImage(box: box, tint: tint)
        .draw(in: NSRect(x: (s - box) / 2, y: (s - box) / 2, width: box, height: box))
}

// ── Release icon: logo on a white squircle ──────────────────────────────

func drawRelease(_ s: CGFloat) {
    NSGraphicsContext.current?.saveGraphicsState()
    squircle(s).addClip()
    // Near-white with a whisper of cool gradient so the squircle reads as a
    // surface (flat #FFF looks like a hole on light backgrounds).
    NSGradient(colors: [
        NSColor.white,
        NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.97, alpha: 1),
    ])!.draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: -90)
    drawLogo(canvas: s, scale: 0.64)
    NSGraphicsContext.current?.restoreGraphicsState()
}

// ── Debug icon: blueprint background, white schematic logo ──────────────

func drawDebug(_ s: CGFloat) {
    NSGraphicsContext.current?.saveGraphicsState()
    let clip = squircle(s)
    clip.addClip()

    // Blueprint paper: vivid blue like Ghostty's Blueprint alternate icon
    // (a dark navy read as "dirty" in the Dock; this stays bright).
    NSGradient(colors: [
        NSColor(calibratedRed: 0.26, green: 0.48, blue: 0.96, alpha: 1),
        NSColor(calibratedRed: 0.14, green: 0.33, blue: 0.85, alpha: 1),
    ])!.draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: -90)

    // Paper grain: deterministic speckle (seeded LCG so builds are stable).
    if s >= 64 {
        var seed: UInt64 = 0x5A17_7E11
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(UInt32.max)
        }
        let dots = Int(s * s / 130)
        for i in 0..<dots {
            let shade: NSColor = i % 2 == 0 ? .white : .black
            shade.withAlphaComponent(0.05).setFill()
            NSRect(x: rnd() * s, y: rnd() * s, width: 1, height: 1).fill()
        }
    }

    // Drafting grid — minor lines with heavier majors every 4th.
    let minor = s / 32
    for i in 1..<32 {
        let major = i % 4 == 0
        NSColor.white.withAlphaComponent(major ? 0.22 : 0.10).setStroke()
        let p = CGFloat(i) * minor
        for line in [NSRect(x: p, y: 0, width: 0, height: s),
                     NSRect(x: 0, y: p, width: s, height: 0)] {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: line.minX, y: line.minY))
            path.line(to: NSPoint(x: line.minX == line.maxX ? line.minX : s,
                                  y: line.minY == line.maxY ? line.minY : s))
            path.lineWidth = max(s / 1024, 0.5)
            path.stroke()
        }
    }

    // Drafting frame: inner rounded square like Ghostty's Blueprint icon.
    NSColor.white.withAlphaComponent(0.55).setStroke()
    let frameInset = s * 0.165
    let frame = NSBezierPath(
        roundedRect: NSRect(x: frameInset, y: frameInset,
                            width: s - 2 * frameInset, height: s - 2 * frameInset),
        xRadius: s * 0.09, yRadius: s * 0.09)
    frame.lineWidth = max(s / 340, 0.6)
    frame.stroke()

    // Construction lines: dashed circle + center crosshair, like a part drawing.
    NSColor.white.withAlphaComponent(0.45).setStroke()
    let r = s * 0.36
    let circle = NSBezierPath(ovalIn: NSRect(x: s / 2 - r, y: s / 2 - r, width: 2 * r, height: 2 * r))
    circle.lineWidth = max(s / 512, 0.5)
    circle.setLineDash([s / 64, s / 96], count: 2, phase: 0)
    circle.stroke()
    let cross = NSBezierPath()
    let tick = s * 0.045
    cross.move(to: NSPoint(x: s / 2 - r - tick, y: s / 2)); cross.line(to: NSPoint(x: s / 2 - r + tick, y: s / 2))
    cross.move(to: NSPoint(x: s / 2 + r - tick, y: s / 2)); cross.line(to: NSPoint(x: s / 2 + r + tick, y: s / 2))
    cross.move(to: NSPoint(x: s / 2, y: s / 2 - r - tick)); cross.line(to: NSPoint(x: s / 2, y: s / 2 - r + tick))
    cross.move(to: NSPoint(x: s / 2, y: s / 2 + r - tick)); cross.line(to: NSPoint(x: s / 2, y: s / 2 + r + tick))
    cross.lineWidth = max(s / 512, 0.5)
    cross.stroke()

    // The logo as a white schematic silhouette — the "prototype" of the icon.
    drawLogo(canvas: s, scale: 0.64, tint: .white)
    NSGraphicsContext.current?.restoreGraphicsState()
}

// ── Emit everything ──────────────────────────────────────────────────────

let sizes = [16, 32, 64, 128, 256, 512, 1024]
print("release (AppIcon):")
for s in sizes {
    renderPNG(size: s, to: "\(repo)/macos/Assets.xcassets/AppIcon.appiconset/icon_\(s).png", draw: drawRelease)
}
print("debug (AppIconDebug):")
for s in sizes {
    renderPNG(size: s, to: "\(repo)/macos/Assets.xcassets/AppIconDebug.appiconset/icon_\(s).png", draw: drawDebug)
}
print("brand image (About window / alerts):")
let imageset = "\(repo)/macos/Assets.xcassets/AppIconImage.imageset"
renderPNG(size: 256, to: "\(imageset)/macOS-AppIcon-256px-128pt@2x.png", draw: drawRelease)
renderPNG(size: 512, to: "\(imageset)/macOS-AppIcon-512px.png", draw: drawRelease)
renderPNG(size: 1024, to: "\(imageset)/macOS-AppIcon-1024px.png", draw: drawRelease)
print("README logo (raw glyph, transparent):")
renderPNG(size: 512, to: "\(repo)/assets/logo.png") { s in drawLogo(canvas: s, scale: 1.0) }
print("done")
