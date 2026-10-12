// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit

/// A text listing of the main menu as the accessibility API reports it:
/// one line per visible item with its shortcut (AX modifier mask, key and
/// key code), "(disabled)" and "✓". The acceptance check compares these
/// listings, per context, with the reference application's menus.
///
///     ## File
///     - Close Comparison [0:W:87]
///     - Revert to Saved (disabled)
@MainActor
enum MenuDump {
    /// The AX modifier mask of an item: 1 Shift, 2 Option, 4 Control,
    /// 8 no Command, 16 Function.
    static func axModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var mask = 0
        if flags.contains(.shift) { mask |= 1 }
        if flags.contains(.option) { mask |= 2 }
        if flags.contains(.control) { mask |= 4 }
        if !flags.contains(.command) { mask |= 8 }
        if flags.contains(.function) { mask |= 16 }
        return mask
    }

    /// " [mods:char:code]" for an item with a key equivalent, "" without.
    /// Letters show in capitals and Return as a line feed, as AX does.
    static func shortcut(_ item: NSMenuItem) -> String {
        guard var key = item.keyEquivalent.first.map(String.init), !key.isEmpty else { return "" }
        if key == "\r" { key = "\n" }
        if key.count == 1, key.lowercased() != key.uppercased() { key = key.uppercased() }
        let code = key.unicodeScalars.first.map { Int($0.value) } ?? 0
        return " [\(axModifiers(item.keyEquivalentModifierMask)):\(key):\(code)]"
    }

    /// Whether `item` would be enabled with `window` in front: its target
    /// (or the handler of its action through the window's responder chain,
    /// then the app delegate and the app) validates it.
    static func isEnabled(_ item: NSMenuItem, in window: NSWindow?, app: NSApplication = NSApp) -> Bool {
        // A submenu's item is enabled (AppKit gives it its own action).
        if item.submenu != nil { return true }
        guard let action = item.action else { return false }
        let target: AnyObject?
        if let explicit = item.target {
            target = explicit
        } else if let window, let found = PrismApplication.target(forAction: action, in: window) as AnyObject? {
            target = found
        } else if let delegate = app.delegate as? NSObject, delegate.responds(to: action) {
            target = delegate
        } else if app.responds(to: action) {
            target = app
        } else {
            target = nil
        }
        guard let target, (target as? NSObject)?.responds(to: action) == true else { return false }
        // The application's own commands (Hide, Show All, Bring All to
        // Front, Minimize All) are enabled in a running app; a test process
        // is not running one.
        if target === app, appCommands.contains(action) { return true }
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return true
    }

    static let appCommands: Set<Selector> = [
        #selector(NSApplication.hide(_:)), #selector(NSApplication.hideOtherApplications(_:)),
        #selector(NSApplication.unhideAllApplications(_:)), #selector(NSApplication.arrangeInFront(_:)),
        #selector(NSApplication.miniaturizeAll(_:)), #selector(NSApplication.terminate(_:)),
    ]

    /// Applies the context menus (hidden items) for `window` in front.
    static func applyContext(_ menu: NSMenu, window: NSWindow?) {
        let handles: (Selector) -> Bool = { action in
            guard let window else { return false }
            return PrismApplication.target(forAction: action, in: window) != nil
        }
        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            if submenu.delegate === MergeMenuContext.shared { MergeMenuContext.update(submenu, handles: handles) }
            if submenu.delegate === ViewMenuContext.shared { ViewMenuContext.update(submenu, handles: handles) }
        }
    }

    /// The listing of `menu` (the main menu) with `window` in front.
    static func dump(_ menu: NSMenu, window: NSWindow?, app: NSApplication = NSApp) -> String {
        applyContext(menu, window: window)
        var out = ""
        for top in menu.items where !top.isHidden {
            guard let submenu = top.submenu else { continue }
            out += "## \(top.title)\n"
            out += dumpItems(submenu, indent: "", window: window, app: app)
        }
        return out
    }

    private static func dumpItems(_ menu: NSMenu, indent: String, window: NSWindow?, app: NSApplication) -> String {
        // Open Recent fills itself; the context menus were applied above.
        if menu.delegate === RecentMenu.shared { RecentMenu.shared.menuNeedsUpdate(menu) }
        var out = ""
        for item in menu.items where !item.isHidden {
            if item.isSeparatorItem {
                out += indent + "---\n"
                continue
            }
            var line = indent + "- " + item.title + shortcut(item)
            if !isEnabled(item, in: window, app: app) { line += " (disabled)" }
            if item.state == .on { line += " \u{2713}" }
            out += line + "\n"
            if let submenu = item.submenu {
                out += dumpItems(submenu, indent: indent + "  ", window: window, app: app)
            }
        }
        return out
    }
}
