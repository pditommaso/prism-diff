// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import PrismProtocol

/// Builds the app's main menu: Prism, File, Edit, View, Merge, Window and
/// Help, with every comparison command and its shortcut. Items whose
/// handler is the app (`target`) are targeted at it; comparison commands
/// go through the responder chain to the key window's selected tab, and
/// validate there, so their enabled state follows the comparison in front.
/// Items that belong to one kind of comparison only are hidden in front
/// of another kind (`MergeMenuContext`, `ViewMenuContext`).
@MainActor
enum MainMenuBuilder {
    static let fileMenuTitle = "File"
    static let editMenuTitle = "Edit"
    static let viewMenuTitle = "View"
    static let mergeMenuTitle = "Merge"
    static let windowMenuTitle = "Window"
    static let helpMenuTitle = "Help"
    static let servicesMenuTitle = "Services"
    static let openRecentTitle = "Open Recent..."

    /// Returns the main menu. `target` receives the app-level commands
    /// (`showAbout:`, `showSettings:`, `showIntegration:`, `newWindow:`,
    /// `newFromClipboard:`, `openDocument:`, `closeAll:`, `zoomAll:`,
    /// `quitKeepingWindows:`, the Help items and Open Recent).
    static func make(target: AnyObject) -> NSMenu {
        let main = NSMenu(title: "Main Menu")
        main.addItem(submenuItem(applicationMenu(target: target)))
        main.addItem(submenuItem(fileMenu(target: target)))
        main.addItem(submenuItem(editMenu()))
        main.addItem(submenuItem(viewMenu()))
        main.addItem(submenuItem(mergeMenu()))
        main.addItem(submenuItem(windowMenu(target: target)))
        main.addItem(submenuItem(helpMenu(target: target)))
        return main
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func add(
        _ menu: NSMenu, _ title: String, _ action: Selector?,
        _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func applicationMenu(target: AnyObject) -> NSMenu {
        let name = PrismInfo.appName
        let menu = NSMenu(title: name)

        let about = add(menu, "About \(name)", #selector(AppDelegate.showAbout(_:)))
        about.target = target
        menu.addItem(.separator())
        let settings = add(menu, "Settings\u{2026}", #selector(AppDelegate.showSettings(_:)), ",")
        settings.target = target
        let integration = add(menu, "Integration\u{2026}", #selector(AppDelegate.showIntegration(_:)))
        integration.target = target
        menu.addItem(.separator())

        let services = NSMenu(title: servicesMenuTitle)
        menu.addItem(submenuItem(services))
        menu.addItem(.separator())

        add(menu, "Hide \(name)", #selector(NSApplication.hide(_:)), "h")
        add(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)),
            "h", [.command, .option])
        add(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())

        add(menu, "Quit \(name)", #selector(NSApplication.terminate(_:)), "q")
        // Option alternate: the windows come back at the next launch.
        let quitKeep = add(menu, "Quit and Keep Windows", #selector(AppDelegate.quitKeepingWindows(_:)),
                           "q", [.command, .option])
        quitKeep.target = target
        quitKeep.isAlternate = true
        return menu
    }

    /// Command-W closes the comparison in front (the selected tab; the
    /// last one closes its window), Shift-Command-W the whole window and
    /// Option-Shift-Command-W every window.
    private static func fileMenu(target: AnyObject) -> NSMenu {
        let menu = NSMenu(title: fileMenuTitle)
        add(menu, "New Window", #selector(AppDelegate.newWindow(_:)), "n").target = target
        add(menu, "New Tab", #selector(DocumentWindowController.newTab(_:)), "t")
        add(menu, "New from Clipboard", #selector(AppDelegate.newFromClipboard(_:)), "n", [.command, .shift])
            .target = target
        add(menu, "Open...", #selector(AppDelegate.openDocument(_:)), "o").target = target
        let recent = NSMenu(title: openRecentTitle)
        recent.delegate = RecentMenu.shared
        RecentMenu.shared.target = target
        let recentItem = submenuItem(recent)
        menu.addItem(recentItem)
        menu.addItem(.separator())
        add(menu, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        // An alternate must directly follow the item it replaces.
        let closeAll = add(menu, "Close All", #selector(AppDelegate.closeAll(_:)), "w",
                           [.command, .shift, .option])
        closeAll.target = target
        closeAll.isAlternate = true
        add(menu, "Close Comparison", #selector(DocumentWindowController.closeComparison(_:)), "w")
        add(menu, "Save", #selector(ComparisonWindowController.saveComparison(_:)), "s")
        add(menu, "Save All", #selector(ComparisonWindowController.saveAllComparisons(_:)), "s", [.command, .shift])
        add(menu, "Revert to Saved", #selector(ComparisonWindowController.revertComparisonToSaved(_:)), "", [])
        return menu
    }

    /// Arrow keys as key equivalents.
    static let upArrow = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
    static let downArrow = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
    static let rightArrow = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
    static let leftArrow = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
    static let backspace = String(Character(UnicodeScalar(NSBackspaceCharacter)!))

    private static func editMenu() -> NSMenu {
        let menu = ShellEditMenu(title: editMenuTitle)
        add(menu, "Undo", Selector(("undo:")), "z")
        add(menu, "Redo", Selector(("redo:")), "z", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Cut", #selector(NSText.cut(_:)), "x")
        add(menu, "Copy", #selector(NSText.copy(_:)), "c")
        add(menu, "Paste", #selector(NSText.paste(_:)), "v")
        add(menu, "Paste to Comparison", #selector(DocumentWindowController.pasteToComparison(_:)), "v",
            [.command, .option])
        add(menu, "Select All", #selector(NSText.selectAll(_:)), "a")
        menu.addItem(.separator())
        add(menu, "Swap A & B", #selector(ComparisonWindowController.swapSides(_:)), "\\")
        add(menu, "Select Next A & B", #selector(DocumentWindowController.selectNextAAndB(_:)), "", [])
        add(menu, "Select Previous A & B", #selector(DocumentWindowController.selectPreviousAAndB(_:)), "", [])
        // Bare and Option arrows: ShellEditMenu lets them through to the
        // text and the lists unless the shelf can use them.
        add(menu, "Select Next A", #selector(ComparisonWindowController.selectNextA(_:)), rightArrow, [.option])
        add(menu, "Select Previous A", #selector(ComparisonWindowController.selectPreviousA(_:)), leftArrow, [.option])
        add(menu, "Select Next B", #selector(ComparisonWindowController.selectNextB(_:)), rightArrow, [])
        add(menu, "Select Previous B", #selector(ComparisonWindowController.selectPreviousB(_:)), leftArrow, [])
        menu.addItem(.separator())
        menu.addItem(submenuItem(findMenu()))
        menu.addItem(.separator())
        menu.addItem(submenuItem(spellingMenu()))
        menu.addItem(submenuItem(speechMenu()))
        return menu
    }

    static let findMenuTitle = "Find"

    /// Edit > Find: the comparison's find bar.
    private static func findMenu() -> NSMenu {
        let menu = NSMenu(title: findMenuTitle)
        add(menu, "Find\u{2026}", #selector(ComparisonWindowController.showFindBar(_:)), "f")
        add(menu, "Find Next", #selector(ComparisonWindowController.findNextMatch(_:)), "g")
        add(menu, "Find Previous", #selector(ComparisonWindowController.findPreviousMatch(_:)), "g", [.command, .shift])
        add(menu, "Use Selection for Find", #selector(ComparisonWindowController.useSelectionForFind(_:)), "e")
        add(menu, "Jump to Selection", #selector(ComparisonWindowController.jumpToSelection(_:)), "j")
        return menu
    }

    private static func spellingMenu() -> NSMenu {
        let menu = NSMenu(title: "Spelling")
        add(menu, "Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":")
        add(menu, "Check Spelling", #selector(NSText.checkSpelling(_:)), ";")
        add(menu, "Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:)), "", [])
        return menu
    }

    private static func speechMenu() -> NSMenu {
        let menu = NSMenu(title: "Speech")
        add(menu, "Start Speaking", #selector(NSTextView.startSpeaking(_:)), "", [])
        add(menu, "Stop Speaking", #selector(NSTextView.stopSpeaking(_:)), "", [])
        return menu
    }

    /// Selectors a 3-way merge comparison answers (declared here so that
    /// the View menu has them in every context; nothing handles them in a
    /// 2-way comparison, so they show disabled).
    static let selectPreviousConflict = Selector(("selectPreviousConflict:"))
    static let selectNextConflict = Selector(("selectNextConflict:"))

    /// The shelf, full screen, file and change navigation, layouts, text
    /// size, wrapping and whitespace.
    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: viewMenuTitle)
        add(menu, "Toggle File Shelf", #selector(DocumentWindowController.toggleFileShelf(_:)), "/")
        add(menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.function])
        menu.addItem(.separator())
        add(menu, "Select Previous File", #selector(ChangesetWindowController.selectPreviousFile(_:)), upArrow,
            [.command, .shift])
        add(menu, "Select Next File", #selector(ChangesetWindowController.selectNextFile(_:)), downArrow,
            [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Blocks", #selector(ComparisonWindowController.showBlocksLayout(_:)), "1")
        add(menu, "Fluid", #selector(ComparisonWindowController.showFluidLayout(_:)), "2")
        add(menu, "Unified", #selector(ComparisonWindowController.showUnifiedLayout(_:)), "3")
        menu.addItem(.separator())
        add(menu, "Previous Change", #selector(ComparisonWindowController.selectPreviousChange(_:)), upArrow)
        add(menu, "Next Change", #selector(ComparisonWindowController.selectNextChange(_:)), downArrow)
        menu.addItem(.separator())
        // Return is bound only while a document window is key (see
        // DocumentWindowController), so it never shadows Return elsewhere.
        add(menu, "Open Selection", #selector(FolderScopeController.openSelection(_:)), "", [])
        menu.addItem(.separator())
        add(menu, "Previous Conflict", selectPreviousConflict, upArrow, [.command, .option])
        add(menu, "Next Conflict", selectNextConflict, downArrow, [.command, .option])
        menu.addItem(.separator())
        add(menu, "Increase Text Size", #selector(ComparisonWindowController.increaseTextSize(_:)), "+")
        add(menu, "Decrease Text Size", #selector(ComparisonWindowController.decreaseTextSize(_:)), "-")
        menu.addItem(.separator())
        add(menu, "Wrap Lines", #selector(ComparisonWindowController.toggleWrapLines(_:)), "k", [.command, .shift])
        add(menu, "Ignore Whitespace", #selector(ComparisonWindowController.toggleIgnoreWhitespace(_:)), "'",
            [.command, .shift])
        menu.delegate = ViewMenuContext.shared
        return menu
    }

    /// Merge: one menu for every kind of window. Copy to Right, Copy to
    /// Left and Reset Selection act on the selected change of a text
    /// comparison or on the selected rows of a folder comparison (the
    /// responder chain picks the handler, and each validates its items;
    /// a 3-way merge retitles them while it validates).
    /// The Keep Both pair belongs to text comparisons and Start Copying
    /// Files to folder comparisons; `MergeMenuContext` hides the items of
    /// the other kind, so their shortcuts never clash.
    private static func mergeMenu() -> NSMenu {
        let menu = NSMenu(title: mergeMenuTitle)
        add(menu, "Copy to Right", #selector(ComparisonWindowController.copyToRight(_:)), rightArrow)
        add(menu, "Copy to Left", #selector(ComparisonWindowController.copyToLeft(_:)), leftArrow)
        add(menu, "Reset Selection", #selector(ComparisonWindowController.resetSelection(_:)), backspace,
            [.command, .option])
        menu.addItem(.separator())
        add(menu, "Keep Both (Left then Right)", #selector(ComparisonWindowController.keepBothLeftFirst(_:)),
            rightArrow, [.command, .option])
        add(menu, "Keep Both (Right then Left)", #selector(ComparisonWindowController.keepBothRightFirst(_:)),
            leftArrow, [.command, .option])
        // Retitled "Cancel Copying Files" while a copy runs.
        add(menu, "Start Copying Files", #selector(FolderScopeController.startCopyingFiles(_:)), "\r")
        menu.delegate = MergeMenuContext.shared
        MergeMenuContext.shared.observeWindows()
        return menu
    }

    private static func windowMenu(target: AnyObject) -> NSMenu {
        let menu = NSMenu(title: windowMenuTitle)
        add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        let minimizeAll = add(menu, "Minimize All", #selector(NSApplication.miniaturizeAll(_:)),
                              "m", [.command, .option])
        minimizeAll.isAlternate = true
        add(menu, "Zoom", #selector(NSWindow.performZoom(_:)), "", [])
        let zoomAll = add(menu, "Zoom All", #selector(AppDelegate.zoomAll(_:)), "", [.option])
        zoomAll.target = target
        zoomAll.isAlternate = true
        menu.addItem(.separator())
        add(menu, "Select Next Tab", #selector(DocumentWindowController.selectNextTab(_:)), "]", [.command, .shift])
        add(menu, "Select Previous Tab", #selector(DocumentWindowController.selectPreviousTab(_:)), "[",
            [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }

    /// The system adds the Help search field once this is `NSApp.helpMenu`.
    /// Prism ships no Help Book, so the entry opens the online documentation
    /// instead of the system's "help isn't available" alert.
    private static func helpMenu(target: AnyObject) -> NSMenu {
        let menu = NSMenu(title: helpMenuTitle)
        let name = PrismInfo.appName
        add(menu, "\(name) Help", #selector(AppDelegate.openHelp(_:)), "?").target = target
        add(menu, "\(name) Website", #selector(AppDelegate.openWebsite(_:)), "", []).target = target
        menu.addItem(.separator())
        add(menu, "Getting Started", #selector(AppDelegate.showGettingStarted(_:)), "", []).target = target
        add(menu, "Send Feedback...", #selector(AppDelegate.sendFeedback(_:)), "", []).target = target
        return menu
    }
}

/// Shows the Merge items of the frontmost comparison's kind: text items
/// for a text comparison (a window, or the selected text tab of a folder
/// window), staging and copy items for a folder comparison. With no
/// comparison in front every item shows, disabled. With no key window the
/// frontmost comparison or folder window decides. AppKit asks for the
/// update before it displays the menu and before it matches a key
/// equivalent, so a hidden item's shortcut never fires.
@MainActor
final class MergeMenuContext: NSObject, NSMenuDelegate {
    static let shared = MergeMenuContext()

    static let textActions: Set<Selector> = [
        #selector(ComparisonWindowController.keepBothLeftFirst(_:)),
        #selector(ComparisonWindowController.keepBothRightFirst(_:)),
    ]
    static let folderActions: Set<Selector> = [#selector(FolderScopeController.startCopyingFiles(_:))]

    /// Only a three-way merge answers this; its window renames the choices.
    static let threeWayAction = #selector(MergeWindowController.selectNextConflict(_:))

    /// Titles of the choices in a two-way comparison and in a three-way
    /// merge, by action.
    static let titles: [Selector: (twoWay: String, threeWay: String)] = [
        #selector(ComparisonWindowController.copyToRight(_:)): ("Copy to Right", "Choose Left"),
        #selector(ComparisonWindowController.copyToLeft(_:)): ("Copy to Left", "Choose Right"),
        #selector(ComparisonWindowController.keepBothLeftFirst(_:)): ("Keep Both (Left then Right)", "Choose Both (Left First)"),
        #selector(ComparisonWindowController.keepBothRightFirst(_:)): ("Keep Both (Right then Left)", "Choose Both (Right First)"),
    ]

    private var observers: [NSObjectProtocol] = []

    func menuNeedsUpdate(_ menu: NSMenu) {
        Self.update(menu) { Self.handler(for: $0) != nil }
    }

    /// Keeps the titles in step with the window in front, so that items
    /// pressed without opening the menu (accessibility) carry the right
    /// names too.
    func observeWindows() {
        guard observers.isEmpty else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                // After the change is complete (a closing window is gone).
                DispatchQueue.main.async { MainActor.assumeIsolated { MergeMenuContext.refresh() } }
            })
        }
    }

    /// Updates the main menu's Merge menu for the window now in front.
    static func refresh() {
        guard let merge = NSApp.mainMenu?.item(withTitle: MainMenuBuilder.mergeMenuTitle)?.submenu else { return }
        update(merge) { handler(for: $0) != nil }
    }

    /// The handler of `action`: through the key window, or, with no key
    /// window (Prism in the background), through the frontmost comparison
    /// or folder window.
    static func handler(for action: Selector, app: NSApplication = NSApp) -> Any? {
        if app.keyWindow == nil, let window = PrismApplication.frontmostDocumentWindow(in: app.orderedWindows) {
            return PrismApplication.target(forAction: action, in: window)
        }
        return app.target(forAction: action, to: nil, from: nil)
    }

    /// Hides the items of the kind that has no handler, when the other
    /// kind has one. `handles` tells whether an action has a target.
    static func update(_ menu: NSMenu, handles: (Selector) -> Bool) {
        let text = textActions.contains(where: handles)
        let folder = folderActions.contains(where: handles)
        let threeWay = handles(threeWayAction)
        for item in menu.items {
            guard let action = item.action else { continue }
            if let names = titles[action] {
                let title = threeWay ? names.threeWay : names.twoWay
                if item.title != title { item.title = title }
            }
            let hidden: Bool
            if textActions.contains(action) {
                hidden = folder && !text
            } else if folderActions.contains(action) {
                hidden = text && !folder
            } else {
                continue
            }
            // Only real changes: the menus are refreshed often in the background.
            if item.isHidden != hidden { item.isHidden = hidden }
        }
    }
}

/// Shows the View items of the comparison in front: layouts, conflicts,
/// text size, wrapping and whitespace for text; Open Selection for
/// folders. Separators around hidden groups are hidden too.
@MainActor
final class ViewMenuContext: NSObject, NSMenuDelegate {
    static let shared = ViewMenuContext()

    static let textActions: Set<Selector> = [
        #selector(ComparisonWindowController.showBlocksLayout(_:)),
        #selector(ComparisonWindowController.showFluidLayout(_:)),
        #selector(ComparisonWindowController.showUnifiedLayout(_:)),
        MainMenuBuilder.selectPreviousConflict, MainMenuBuilder.selectNextConflict,
        #selector(ComparisonWindowController.increaseTextSize(_:)),
        #selector(ComparisonWindowController.decreaseTextSize(_:)),
        #selector(ComparisonWindowController.toggleWrapLines(_:)),
        #selector(ComparisonWindowController.toggleIgnoreWhitespace(_:)),
    ]
    static let folderActions: Set<Selector> = [#selector(FolderScopeController.openSelection(_:))]

    func menuNeedsUpdate(_ menu: NSMenu) {
        Self.update(menu) { MergeMenuContext.handler(for: $0) != nil }
    }

    /// `handles` tells whether an action has a target in front.
    static func update(_ menu: NSMenu, handles: (Selector) -> Bool) {
        let text = handles(#selector(ComparisonWindowController.showBlocksLayout(_:)))
        let folder = handles(#selector(FolderScopeController.openSelection(_:)))
        for item in menu.items {
            guard let action = item.action else { continue }
            let hidden: Bool
            if textActions.contains(action) {
                hidden = folder && !text
            } else if folderActions.contains(action) {
                hidden = !folder
            } else {
                continue
            }
            // Only real changes: the menus are refreshed often in the background.
            if item.isHidden != hidden { item.isHidden = hidden }
        }
        tidySeparators(menu)
    }

    /// Hides separators that would be leading, trailing or doubled.
    static func tidySeparators(_ menu: NSMenu) {
        var previousVisibleIsSeparator = true
        var lastSeparator: NSMenuItem?
        for item in menu.items {
            if item.isSeparatorItem {
                if item.isHidden != previousVisibleIsSeparator { item.isHidden = previousVisibleIsSeparator }
                if !item.isHidden {
                    previousVisibleIsSeparator = true
                    lastSeparator = item
                }
            } else if !item.isHidden {
                previousVisibleIsSeparator = false
                lastSeparator = nil
            }
        }
        if lastSeparator?.isHidden == false { lastSeparator?.isHidden = true }
    }
}

/// The Edit menu. Its shelf items use bare and Option arrows, which the
/// menu would otherwise take from every text view and list (a disabled
/// item still swallows its key). They reach the shelf only when it can use
/// them: the item is enabled and no text field is being edited.
final class ShellEditMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Key equivalents arrive on the main thread.
        nonisolated(unsafe) let event = event
        nonisolated(unsafe) let menu = self
        let handled: Bool? = MainActor.assumeIsolated {
            guard let item = Self.arrowItem(in: menu, for: event) else { return nil }
            menu.update()
            let editing = NSApp.keyWindow?.firstResponder is NSText
            guard item.isEnabled, !editing, let action = item.action else { return false }
            return NSApp.sendAction(action, to: item.target, from: item)
        }
        return handled ?? super.performKeyEquivalent(with: event)
    }

    /// The item an arrow key without Command or Control would trigger.
    @MainActor
    static func arrowItem(in menu: NSMenu, for event: NSEvent) -> NSMenuItem? {
        guard event.type == .keyDown, let key = event.charactersIgnoringModifiers,
              key == MainMenuBuilder.leftArrow || key == MainMenuBuilder.rightArrow else { return nil }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.contains(.command), !flags.contains(.control) else { return nil }
        return menu.items.first { item in
            item.keyEquivalent == key && item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift])
                == flags
        }
    }
}
