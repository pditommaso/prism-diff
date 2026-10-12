// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso
//
// Draws Prism's placeholder app icon and writes a complete .iconset folder
// (16, 32, 128, 256 and 512 points at 1x and 2x) ready for `iconutil`.
//
// Usage: swift scripts/tools/make-icon.swift <out.iconset>
//
// Artwork: a rounded square with a deep blue-to-violet gradient, a white
// triangular prism and a fan of spectrum bands leaving its right face.

import AppKit
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// Draws the artwork into a square bitmap of `pixels` x `pixels`.
func render(pixels: Int) -> CGImage {
    let size = CGFloat(pixels)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
              bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("cannot create a \(pixels)px bitmap context") }

    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Background tile: macOS-style margin (about 10%) and corner radius.
    let inset = size * 0.1
    let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = tile.width * 0.225
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                  color: color(0, 0, 0, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0.10, 0.12, 0.30))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let background = CGGradient(
        colorsSpace: space,
        colors: [color(0.09, 0.20, 0.45), color(0.27, 0.13, 0.48)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: tile.minX, y: tile.maxY),
                           end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

    // Prism: equilateral triangle, slightly left of centre.
    let side = tile.width * 0.52
    let height = side * sqrt(3) / 2
    let cx = tile.midX - tile.width * 0.08
    let base = tile.midY - height / 2.6
    let apex = CGPoint(x: cx, y: base + height)
    let left = CGPoint(x: cx - side / 2, y: base)
    let right = CGPoint(x: cx + side / 2, y: base)

    // Spectrum fan from the middle of the right face to the right edge.
    let exit = CGPoint(x: (apex.x + right.x) / 2, y: (apex.y + right.y) / 2)
    let bands: [CGColor] = [
        color(0.96, 0.26, 0.27), color(0.98, 0.58, 0.20), color(0.99, 0.86, 0.27),
        color(0.36, 0.80, 0.40), color(0.25, 0.60, 0.98), color(0.58, 0.40, 0.95),
    ]
    let fanTop = tile.midY + tile.height * 0.06
    let fanBottom = tile.midY - tile.height * 0.30
    let step = (fanTop - fanBottom) / CGFloat(bands.count)
    for (index, band) in bands.enumerated() {
        let top = fanTop - CGFloat(index) * step
        ctx.beginPath()
        ctx.move(to: exit)
        ctx.addLine(to: CGPoint(x: tile.maxX + 1, y: top))
        ctx.addLine(to: CGPoint(x: tile.maxX + 1, y: top - step))
        ctx.closePath()
        ctx.setFillColor(band)
        ctx.fillPath()
    }

    // Incoming white beam on the left face.
    let entry = CGPoint(x: (apex.x + left.x) / 2, y: (apex.y + left.y) / 2)
    ctx.setStrokeColor(color(1, 1, 1, 0.9))
    ctx.setLineWidth(max(1, size * 0.018))
    ctx.setLineCap(.round)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: tile.minX + tile.width * 0.04, y: entry.y - tile.height * 0.10))
    ctx.addLine(to: entry)
    ctx.strokePath()

    // The prism itself: white with a soft vertical shade.
    let prism = CGMutablePath()
    prism.move(to: apex)
    prism.addLine(to: right)
    prism.addLine(to: left)
    prism.closeSubpath()
    ctx.saveGState()
    ctx.addPath(prism)
    ctx.clip()
    let glass = CGGradient(
        colorsSpace: space,
        colors: [color(1, 1, 1), color(0.86, 0.89, 0.96)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(glass, start: apex, end: CGPoint(x: cx, y: base), options: [])
    ctx.restoreGState()
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { fail("cannot render \(pixels)px image") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fail("cannot encode \(url.lastPathComponent)")
    }
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        fail("cannot write \(url.path): \(error.localizedDescription)")
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 2, arguments[1].hasSuffix(".iconset") else {
    fail("usage: swift scripts/tools/make-icon.swift <out.iconset>")
}
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
} catch {
    fail("cannot create \(output.path): \(error.localizedDescription)")
}

for points in [16, 32, 128, 256, 512] {
    writePNG(render(pixels: points), to: output.appending(path: "icon_\(points)x\(points).png"))
    writePNG(render(pixels: points * 2), to: output.appending(path: "icon_\(points)x\(points)@2x.png"))
}
print(output.path)
