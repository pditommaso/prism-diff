// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso
//
// Prints the sRGB colour of one pixel of an image as #RRGGBB.
//
// Usage: pixel <image.png> <x> <y>    (pixels, origin at the top left)
// Exit status: 0 on success, 1 when the image cannot be read or the point
// is outside it, 2 on a usage error.
//
// Compiled on demand by scripts/accept/lib.sh into build/tools/pixel.

import CoreGraphics
import Foundation
import ImageIO

let arguments = CommandLine.arguments
guard arguments.count == 4, let x = Int(arguments[2]), let y = Int(arguments[3]) else {
    FileHandle.standardError.write(Data("usage: pixel <image.png> <x> <y>\n".utf8))
    exit(2)
}
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      x >= 0, y >= 0, x < image.width, y < image.height,
      let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
      let space = CGColorSpace(name: CGColorSpace.sRGB)
else {
    FileHandle.standardError.write(Data("pixel: cannot read that pixel\n".utf8))
    exit(1)
}
var rgba = [UInt8](repeating: 0, count: 4)
let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return true
}
guard drawn else { exit(1) }
print(String(format: "#%02X%02X%02X", rgba[0], rgba[1], rgba[2]))
