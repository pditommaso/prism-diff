// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso
//
// Drives one process through the Accessibility API, by PID, without
// bringing it to the front: AXPress and AXSelected work on a background
// app, so acceptance runs never take the focus from the user.
//
// Usage:
//   axpress <pid> id <identifier>              AXPress the element with that AXIdentifier
//   axpress <pid> value <identifier>           print its AXValue
//   axpress <pid> button <title>               AXPress the first button with that title
//                                              (sheets and alerts included)
//   axpress <pid> menu <menu> <item>           AXPress a menu bar item, e.g. Merge "Copy to Right"
//                                              ("Undo" also matches "Undo <action>")
//   axpress <pid> select <identifier> <row>    select row <row> (0-based) of the table with
//                                              that identifier
//   axpress <pid> action <identifier> <name>   perform the element's custom action whose
//                                              name contains <name> (e.g. a tab's
//                                              "Move Tab to New Window")
//
// Exit status: 0 on success, 1 when the element is missing or the action
// failed, 2 on a usage error. Needs the Accessibility permission.
//
// Compiled on demand by scripts/accept/lib.sh (accept_tool) into build/tools/axpress.

import ApplicationServices
import Foundation

func usage(_ message: String) -> Never {
    FileHandle.standardError.write(Data("axpress: \(message)\n".utf8))
    exit(2)
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

/// Depth-first search, at most `limit` elements visited.
func find(_ root: AXUIElement, limit: Int = 20_000, _ matches: (AXUIElement) -> Bool) -> AXUIElement? {
    var stack = [root], visited = 0
    while let element = stack.popLast(), visited < limit {
        visited += 1
        if matches(element) { return element }
        stack.append(contentsOf: children(element).reversed())
    }
    return nil
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3, let pid = Int32(arguments[0]) else { usage("usage: axpress <pid> <command> <args>") }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 10)

func press(_ element: AXUIElement?) -> Int32 {
    guard let element else {
        FileHandle.standardError.write(Data("axpress: element not found\n".utf8))
        return 1
    }
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    if result != .success { FileHandle.standardError.write(Data("axpress: AXPress failed (\(result.rawValue))\n".utf8)) }
    return result == .success ? 0 : 1
}

func byIdentifier(_ identifier: String, in app: AXUIElement) -> AXUIElement? {
    var windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    if windows.isEmpty { windows = [app] }
    for window in windows {
        if let found = find(window, { attribute($0, kAXIdentifierAttribute) as? String == identifier }) { return found }
    }
    return nil
}

switch arguments[1] {
case "id":
    exit(press(byIdentifier(arguments[2], in: app)))
case "value":
    guard let element = byIdentifier(arguments[2], in: app) else { exit(1) }
    print(attribute(element, kAXValueAttribute).map { "\($0)" } ?? "")
case "button":
    let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    let button = windows.lazy.compactMap { window in
        find(window) {
            attribute($0, kAXRoleAttribute) as? String == kAXButtonRole
                && attribute($0, kAXTitleAttribute) as? String == arguments[2]
        }
    }.first
    exit(press(button))
case "menu":
    guard arguments.count == 4 else { usage("menu needs <menu> <item>") }
    guard let bar = attribute(app, kAXMenuBarAttribute) else { exit(1) }
    // swiftlint:disable:next force_cast
    let menuBar = bar as! AXUIElement
    guard let menu = children(menuBar).first(where: { attribute($0, kAXTitleAttribute) as? String == arguments[2] }) else {
        FileHandle.standardError.write(Data("axpress: no menu \(arguments[2])\n".utf8))
        exit(1)
    }
    // The exact title, else one that starts with it and a space: "Undo"
    // also finds "Undo Copy to Right", whose title names the action.
    func item(_ matches: (String) -> Bool) -> AXUIElement? {
        find(menu) {
            attribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole
                && (attribute($0, kAXTitleAttribute) as? String).map(matches) == true
        }
    }
    exit(press(item { $0 == arguments[3] } ?? item { $0.hasPrefix(arguments[3] + " ") }))
case "select":
    guard arguments.count == 4, let row = Int(arguments[3]) else { usage("select needs <identifier> <row>") }
    guard let table = byIdentifier(arguments[2], in: app) else { exit(1) }
    let rows = (attribute(table, kAXRowsAttribute) as? [AXUIElement]) ?? []
    guard rows.indices.contains(row) else { exit(1) }
    let result = AXUIElementSetAttributeValue(rows[row], kAXSelectedAttribute as CFString, kCFBooleanTrue)
    exit(result == .success ? 0 : 1)
case "action":
    guard arguments.count == 4 else { usage("action needs <identifier> <name>") }
    guard let element = byIdentifier(arguments[2], in: app) else { exit(1) }
    var names: CFArray?
    AXUIElementCopyActionNames(element, &names)
    guard let action = (names as? [String])?.first(where: { $0.contains(arguments[3]) }) else {
        FileHandle.standardError.write(Data("axpress: no action \(arguments[3])\n".utf8))
        exit(1)
    }
    exit(AXUIElementPerformAction(element, action as CFString) == .success ? 0 : 1)
default:
    usage("unknown command \(arguments[1])")
}
