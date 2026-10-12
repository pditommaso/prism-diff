// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso
//
// axmenu <pid>: prints the menu bar of the process as the accessibility API
// reports it, in the listing format of scripts/accept/tools/menucompare.py:
//
//   ## File
//   - Close Comparison [0:W:87]
//   - Revert to Saved (disabled)
//
// It reads attributes only (no menu is opened, nothing is clicked), so the
// app may stay in the background. Needs the Accessibility permission.
import ApplicationServices
import Foundation

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func dump(_ menu: AXUIElement, indent: String) -> String {
    var out = ""
    for item in children(menu) {
        let title = attribute(item, kAXTitleAttribute) as? String ?? ""
        if title.isEmpty {
            out += indent + "---\n"
            continue
        }
        var line = indent + "- " + title
        if let char = attribute(item, kAXMenuItemCmdCharAttribute) as? String, !char.isEmpty {
            let mods = (attribute(item, kAXMenuItemCmdModifiersAttribute) as? Int) ?? 0
            let code = char.unicodeScalars.first.map { Int($0.value) } ?? 0
            line += " [\(mods):\(char):\(code)]"
        } else if let key = attribute(item, kAXMenuItemCmdVirtualKeyAttribute) as? Int {
            line += " [vk \(key)]"
        }
        if (attribute(item, kAXEnabledAttribute) as? Bool) == false { line += " (disabled)" }
        if let mark = attribute(item, kAXMenuItemMarkCharAttribute) as? String, !mark.isEmpty { line += " \u{2713}" }
        out += line + "\n"
        for submenu in children(item) {
            out += dump(submenu, indent: indent + "  ")
        }
    }
    return out
}

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: axmenu <pid>\n".utf8))
    exit(2)
}
let app = AXUIElementCreateApplication(pid)
guard let bar = attribute(app, kAXMenuBarAttribute) else {
    FileHandle.standardError.write(Data("axmenu: no menu bar (Accessibility permission?)\n".utf8))
    exit(1)
}
var listing = ""
// swiftlint:disable:next force_cast
for top in children(bar as! AXUIElement) {
    let title = attribute(top, kAXTitleAttribute) as? String ?? ""
    if title.isEmpty || title == "Apple" { continue }
    listing += "## \(title)\n"
    for menu in children(top) { listing += dump(menu, indent: "") }
}
print(listing, terminator: "")
