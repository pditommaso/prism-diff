// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso
//
// Lists on-screen windows owned by a process, one per line, tab separated:
//
//   <window id> <layer> <x>,<y>,<width>,<height> <owner pid> <title>
//
// Usage: winlist [--all] <owner name>
//   --all  include off-screen windows as well
//
// Window titles need the Screen Recording permission; without it the title
// column is empty but ids, layers and bounds are still listed.
// Exit status: 0 when at least one window matched, 1 when none did, 2 on a
// usage error.
//
// Compiled on demand by scripts/accept/lib.sh into build/tools/winlist.

import CoreGraphics
import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())
var options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
if arguments.first == "--all" {
    options = [.optionAll]
    arguments.removeFirst()
}
guard arguments.count == 1, !arguments[0].isEmpty else {
    FileHandle.standardError.write(Data("usage: winlist [--all] <owner name>\n".utf8))
    exit(2)
}
let owner = arguments[0]

let windows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
var matched = 0
for window in windows {
    guard (window[kCGWindowOwnerName as String] as? String) == owner,
          let id = window[kCGWindowNumber as String] as? Int
    else { continue }
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    let pid = window[kCGWindowOwnerPID as String] as? Int ?? 0
    let title = (window[kCGWindowName as String] as? String) ?? ""
    var bounds = CGRect.zero
    if let dict = window[kCGWindowBounds as String] as? NSDictionary as CFDictionary? {
        bounds = CGRect(dictionaryRepresentation: dict) ?? .zero
    }
    let frame = "\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height))"
    print("\(id)\t\(layer)\t\(frame)\t\(pid)\t\(title)")
    matched += 1
}
exit(matched > 0 ? 0 : 1)
