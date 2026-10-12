// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso
//
// Recognizes the text in a screenshot with Vision and prints one line per
// recognized text run, tab separated, in image pixels with the origin at
// the top left:
//
//   <mid y> <min x> <max x> <text>
//
// Usage: ocrrows <image.png>
// Exit status: 0 on success, 1 when the image cannot be read or recognized,
// 2 on a usage error.
//
// Compiled on demand by scripts/accept/lib.sh into build/tools/ocrrows.

import CoreGraphics
import Foundation
import ImageIO
import Vision

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: ocrrows <image.png>\n".utf8))
    exit(2)
}
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    FileHandle.standardError.write(Data("ocrrows: cannot read \(arguments[1])\n".utf8))
    exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(cgImage: image, options: [:])
do {
    try handler.perform([request])
} catch {
    FileHandle.standardError.write(Data("ocrrows: \(error)\n".utf8))
    exit(1)
}
let width = Double(image.width), height = Double(image.height)
for observation in request.results ?? [] {
    guard let text = observation.topCandidates(1).first?.string else { continue }
    let box = observation.boundingBox
    let midY = (1 - box.midY) * height
    print(String(format: "%.1f\t%.1f\t%.1f\t%@", midY, box.minX * width, box.maxX * width, text))
}
