#!/usr/bin/env swift
// Draws the Battery Buddy app icon and packs it into Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift <out.iconset> [out.icns]
//
// Writes every iconset PNG (16…1024 px) into <out.iconset>, then runs
// `iconutil -c icns` to produce [out.icns] (default: Resources/AppIcon.icns next to this
// script's parent directory). All artwork is drawn here with CoreGraphics; no assets.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let tileTop = rgb(0xFFFFFF)
let tileBottom = rgb(0xE3F3E8)
let ink = rgb(0x26323D)          // battery outline + terminal
let chargeTop = rgb(0x4CD964)
let chargeBottom = rgb(0x22A447)
let boltFill = rgb(0xFFFFFF)

// MARK: - Drawing (1024 × 1024 design space, origin bottom-left)

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func linearGradient(_ ctx: CGContext, in path: CGPath, top: CGColor, bottom: CGColor) {
    let box = path.boundingBox
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray,
                       locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(g, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY),
                           options: [])
    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    let small = pixels <= 32 // tiny sizes: no shadow, chunkier strokes

    // Tile: macOS icon grid puts an 824 pt rounded square inside the 1024 canvas.
    let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = roundedRect(tileRect, 185)
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.28))
        ctx.addPath(tile)
        ctx.setFillColor(tileTop)
        ctx.fillPath()
        ctx.restoreGState()
    }
    linearGradient(ctx, in: tile, top: tileTop, bottom: tileBottom)
    ctx.addPath(tile)
    ctx.setStrokeColor(rgb(0x000000, 0.08))
    ctx.setLineWidth(small ? 16 : 4)
    ctx.strokePath()

    // Battery body.
    let stroke: CGFloat = small ? 64 : 44
    let body = CGRect(x: 214, y: 340, width: 548, height: 344)
    let bodyRadius: CGFloat = 92
    let nub = CGRect(x: body.maxX + stroke / 2 + 10, y: body.midY - 72, width: 52, height: 144)
    ctx.addPath(roundedRect(nub, 26))
    ctx.setFillColor(ink)
    ctx.fillPath()

    // Charge level: green, clipped to the inner rounded rect.
    let gap: CGFloat = small ? 30 : 26
    let inner = body.insetBy(dx: stroke / 2 + gap, dy: stroke / 2 + gap)
    let innerPath = roundedRect(inner, bodyRadius - stroke / 2 - gap)
    let level: CGFloat = 0.8
    let fillWidth = inner.width * level
    ctx.saveGState()
    ctx.addPath(innerPath)
    ctx.clip()
    // Extend left past the clip so only the leading edge shows its (softer) rounding.
    let fill = roundedRect(CGRect(x: inner.minX - 60, y: inner.minY, width: fillWidth + 60, height: inner.height),
                           small ? 8 : 24)
    linearGradient(ctx, in: fill, top: chargeTop, bottom: chargeBottom)
    ctx.restoreGState()

    ctx.addPath(roundedRect(body, bodyRadius))
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(stroke)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Lightning bolt, centred on the green charge. Skipped at 16 px, where it turns to mush.
    guard pixels > 16 else { return }
    let c = CGPoint(x: inner.minX + fillWidth / 2 + 4, y: inner.midY)
    let s: CGFloat = small ? 0.92 : 0.84
    let outline: [(CGFloat, CGFloat)] = [(28, 150), (-92, -14), (-8, -14), (-34, -150), (92, 22), (8, 22)]
    let pts = outline.map { CGPoint(x: c.x + $0.0 * s, y: c.y + $0.1 * s) }
    let bolt = CGMutablePath()
    bolt.addLines(between: pts)
    bolt.closeSubpath()
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: rgb(0x0B5A23, 0.35))
        ctx.addPath(bolt)
        ctx.setFillColor(boltFill)
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.addPath(bolt)
    ctx.setFillColor(boltFill)
    ctx.setStrokeColor(boltFill)
    ctx.setLineWidth(small ? 14 : 10)
    ctx.setLineJoin(.round)
    ctx.drawPath(using: .fillStroke)
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    drawIcon(ctx, pixels: pixels)
    gc.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: swift scripts/make-icon.swift <out.iconset> [out.icns]\n".data(using: .utf8)!)
    exit(2)
}
let scriptDir = URL(fileURLWithPath: args[0]).deletingLastPathComponent()
let iconset = URL(fileURLWithPath: args[1])
let icns = args.count >= 3 ? URL(fileURLWithPath: args[2])
    : scriptDir.appendingPathComponent("../Resources/AppIcon.icns").standardizedFileURL

let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png(pixels: base * factor).write(to: iconset.appendingPathComponent(name))
    }
}

try fm.createDirectory(at: icns.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { exit(p.terminationStatus) }
print(icns.path)
