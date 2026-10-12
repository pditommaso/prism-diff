// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit

/// The application object. While no window is key (Prism in the
/// background, as under `PRISM_TESTING=1`, or driven through accessibility
/// actions), menu commands with no explicit target, and their validation,
/// go to the frontmost comparison or folder window instead of reaching no
/// window at all. Edit > Undo and Redo follow, since that window answers
/// them with its own undo manager (and so names the action in their
/// titles).
///
/// AppKit validates menu items when a menu opens or a key equivalent is
/// matched, neither of which happens to an app in the background: an
/// accessibility client would read stale titles (no "Redo Copy to Right"
/// after an Undo) and press items still disabled from an earlier state.
/// So while no window is key the menus are validated again after every
/// command and whenever the main run loop is about to wait.
@objc(PrismApplication)
final class PrismApplication: NSApplication {
    private var menuRefresher: CFRunLoopObserver?

    override func finishLaunching() {
        super.finishLaunching()
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated {
                guard let app = NSApp as? PrismApplication else { return }
                app.refreshMenusInBackground()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        menuRefresher = observer
    }

    /// Validates every menu again while no window is key (see above).
    func refreshMenusInBackground() {
        guard keyWindow == nil, let mainMenu else { return }
        Self.refresh(mainMenu)
    }

    /// Updates `menu` and its submenus as AppKit does before showing them:
    /// the delegate first (it may show or hide items), then validation.
    static func refresh(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        for item in menu.items {
            if let submenu = item.submenu { refresh(submenu) }
        }
    }

    override func target(forAction action: Selector, to target: Any?, from sender: Any?) -> Any? {
        if target == nil, keyWindow == nil, Self.isMenuCommand(action, sender: sender, menu: mainMenu),
           let window = Self.frontmostDocumentWindow(in: orderedWindows),
           let found = Self.target(forAction: action, in: window) {
            return found
        }
        return super.target(forAction: action, to: target, from: sender)
    }

    override func sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
        if target == nil, keyWindow == nil, Self.isMenuCommand(action, sender: sender, menu: mainMenu),
           let window = Self.frontmostDocumentWindow(in: orderedWindows),
           let found = Self.target(forAction: action, in: window) {
            let sent = super.sendAction(action, to: found, from: sender)
            refreshMenusInBackground()
            return sent
        }
        let sent = super.sendAction(action, to: target, from: sender)
        refreshMenusInBackground()
        return sent
    }

    /// Only menu commands are routed: an action sent or validated by a menu
    /// item, or one that some main-menu item sends. AppKit also looks up
    /// targets for its own purposes (accessibility among them); those keep
    /// the standard lookup.
    static func isMenuCommand(_ action: Selector, sender: Any?, menu: NSMenu?) -> Bool {
        if sender is NSMenuItem { return true }
        return menu.map { contains(action, in: $0) } ?? false
    }

    private static func contains(_ action: Selector, in menu: NSMenu) -> Bool {
        menu.items.contains { item in
            item.action == action || item.submenu.map { contains(action, in: $0) } == true
        }
    }

    /// The first visible window, front to back, that shows a text or a
    /// folder comparison.
    static func frontmostDocumentWindow(in windows: [NSWindow],
                                        isVisible: (NSWindow) -> Bool = { $0.isVisible }) -> NSWindow? {
        windows.first { window in
            isVisible(window)
                && (window.windowController is ComparisonWindowController
                    || window.windowController is DocumentWindowController
                    || window.windowController is MergeWindowController)
        }
    }

    /// What handles `action` in `window`, as if it were key: its responder
    /// chain from the first responder (each responder's supplemental
    /// target included, such as a folder window's selected tab), then the
    /// window's delegate.
    static func target(forAction action: Selector, in window: NSWindow) -> Any? {
        var responder: NSResponder? = window.firstResponder ?? window
        while let current = responder {
            if current.responds(to: action) { return current }
            if let supplemental = current.supplementalTarget(forAction: action, sender: nil) {
                return supplemental
            }
            responder = current.nextResponder
        }
        if let delegate = window.delegate as? NSObject, delegate.responds(to: action) { return delegate }
        return nil
    }
}
