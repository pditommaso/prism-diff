// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import Testing
import PrismProtocol
@testable import PrismApp

@Test func appVersionLineNamesProduct() {
    #expect(PrismAppMain.versionLine().hasPrefix("Prism \(PrismInfo.version)"))
}

@Test func aboutContentCarriesVersionAndLicence() {
    let content = AboutContent.current
    #expect(content.title == "Prism")
    #expect(content.versionLine == "Version \(PrismInfo.version) (\(PrismInfo.build))")
    #expect(content.licenseLine.contains("Apache"))
    #expect(content.disclaimer.contains("not affiliated"))
    #expect(content.sourceURL.absoluteString == "https://github.com/pditommaso/prism-diff")
}

@Test func plainLaunchShowsAboutUnlessSuppressed() {
    // A plain `open build/Prism.app` passes no arguments: About must show.
    #expect(AppDelegate.wantsAboutAtLaunch(arguments: ["PrismApp"], environment: [:]))
    #expect(AppDelegate.wantsAboutAtLaunch(arguments: ["PrismApp"], environment: ["PRISM_SHOW_ABOUT": "1"]))
    #expect(!AppDelegate.wantsAboutAtLaunch(arguments: ["PrismApp", "--no-about"], environment: [:]))
    #expect(!AppDelegate.wantsAboutAtLaunch(arguments: ["PrismApp"], environment: ["PRISM_SHOW_ABOUT": "0"]))
    // Only arguments after the executable path count.
    #expect(AppDelegate.wantsAboutAtLaunch(arguments: ["--no-about"], environment: [:]))
}

@MainActor
@Test func applicationMenuHasAboutAndQuit() throws {
    let target = NSObject()
    let menu = MainMenuBuilder.make(target: target)
    let appMenu = try #require(menu.items.first?.submenu)
    #expect(appMenu.title == "Prism")

    let about = try #require(appMenu.item(withTitle: "About Prism"))
    #expect(about.action == NSSelectorFromString("showAbout:"))
    #expect(about.target === target)

    let quit = try #require(appMenu.item(withTitle: "Quit Prism"))
    #expect(quit.keyEquivalent == "q")
    #expect(quit.action == #selector(NSApplication.terminate(_:)))

    let hideOthers = try #require(appMenu.item(withTitle: "Hide Others"))
    #expect(hideOthers.keyEquivalentModifierMask == [.command, .option])
}

@MainActor
@Test func mainMenuHasStandardMenusInOrder() {
    let menu = MainMenuBuilder.make(target: NSObject())
    #expect(menu.items.map(\.title) == ["Prism", "File", "Edit", "View", "Merge", "Window", "Help"])
    #expect(menu.items.first?.submenu?.item(withTitle: MainMenuBuilder.servicesMenuTitle)?.submenu != nil)
}

@MainActor
@Test func windowMenuHasMinimizeZoomAndBringAllToFront() throws {
    let menu = MainMenuBuilder.make(target: NSObject())
    let windowMenu = try #require(menu.item(withTitle: MainMenuBuilder.windowMenuTitle)?.submenu)
    #expect(windowMenu.item(withTitle: "Minimize")?.keyEquivalent == "m")
    #expect(windowMenu.item(withTitle: "Zoom") != nil)
    #expect(windowMenu.item(withTitle: "Bring All to Front")?.action
        == #selector(NSApplication.arrangeInFront(_:)))
}

/// Finds the item bound to Cmd-<key> (no other modifiers) anywhere in the
/// menu tree.
@MainActor
private func item(in menu: NSMenu, commandKey key: String) -> NSMenuItem? {
    for entry in menu.items {
        if entry.keyEquivalent == key && entry.keyEquivalentModifierMask == .command {
            return entry
        }
        if let sub = entry.submenu, let found = item(in: sub, commandKey: key) {
            return found
        }
    }
    return nil
}

/// Command-W closes the comparison in front (M10): the selected tab of a
/// document window, or any other key window (the app delegate's fallback).
@MainActor
@Test func commandWClosesTheComparisonInFront() throws {
    let menu = MainMenuBuilder.make(target: NSObject())
    let close = try #require(item(in: menu, commandKey: "w"))
    #expect(close.title == "Close Comparison")
    #expect(close.action == #selector(DocumentWindowController.closeComparison(_:)))
    #expect(close.target == nil)  // goes to the key window via the responder chain
    #expect(AppDelegate.instancesRespond(to: #selector(DocumentWindowController.closeComparison(_:))))
}

@MainActor
@Test func fileMenuCloseShortcutsFollowTheReferenceLayout() throws {
    let target = NSObject()
    let menu = MainMenuBuilder.make(target: target)
    let file = try #require(menu.item(withTitle: MainMenuBuilder.fileMenuTitle)?.submenu)

    let window = try #require(file.item(withTitle: "Close Window"))
    #expect(window.keyEquivalent == "w")
    #expect(window.keyEquivalentModifierMask == [.command, .shift])
    #expect(window.action == #selector(NSWindow.performClose(_:)))
    #expect(window.target == nil)

    let all = try #require(file.item(withTitle: "Close All"))
    #expect(all.keyEquivalent == "w")
    #expect(all.keyEquivalentModifierMask == [.command, .shift, .option])
    #expect(all.isAlternate)
    #expect(all.action == NSSelectorFromString("closeAll:"))
    #expect(all.target === target)
}

@MainActor
@Test func helpMenuOpensTheOnlineDocumentation() throws {
    let target = NSObject()
    let menu = MainMenuBuilder.make(target: target)
    let help = try #require(menu.item(withTitle: MainMenuBuilder.helpMenuTitle)?.submenu)
    let entry = try #require(help.item(withTitle: "Prism Help"))
    #expect(entry.keyEquivalent == "?")
    // Not NSApplication.showHelp(_:): without a Help Book it only shows an
    // alert saying help is unavailable.
    #expect(entry.action == NSSelectorFromString("openHelp:"))
    #expect(entry.target === target)
    #expect(AppDelegate.helpURL.absoluteString.hasPrefix("https://github.com/pditommaso/prism-diff"))
}

@MainActor
@Test func fileMenuOrderPutsCloseWindowFirst() throws {
    let menu = MainMenuBuilder.make(target: NSObject())
    let file = try #require(menu.item(withTitle: MainMenuBuilder.fileMenuTitle)?.submenu)
    #expect(file.items.map(\.title) == ["New Window", "New Tab", "New from Clipboard", "Open...", "Open Recent...", "",
                                        "Close Window", "Close All", "Close Comparison",
                                        "Save", "Save All", "Revert to Saved"])
}

/// An alternate item must directly follow an item with the same key
/// equivalent and differ from it by the Option modifier, or AppKit shows
/// both items side by side.
@MainActor
private func expectAlternate(_ menu: NSMenu, _ base: String, _ alternate: String) throws {
    let index = menu.indexOfItem(withTitle: alternate)
    try #require(index > 0)
    let alt = try #require(menu.item(at: index))
    let primary = try #require(menu.item(at: index - 1))
    #expect(primary.title == base)
    #expect(alt.isAlternate)
    #expect(!primary.isAlternate)
    #expect(alt.keyEquivalent == primary.keyEquivalent)
    #expect(alt.keyEquivalentModifierMask == primary.keyEquivalentModifierMask.union(.option))
    #expect(!primary.keyEquivalentModifierMask.contains(.option))
}

@MainActor
@Test func optionAlternatesForQuitCloseMinimizeAndZoom() throws {
    let target = NSObject()
    let menu = MainMenuBuilder.make(target: target)
    let app = try #require(menu.items.first?.submenu)
    let file = try #require(menu.item(withTitle: MainMenuBuilder.fileMenuTitle)?.submenu)
    let window = try #require(menu.item(withTitle: MainMenuBuilder.windowMenuTitle)?.submenu)
    try expectAlternate(app, "Quit Prism", "Quit and Keep Windows")
    try expectAlternate(file, "Close Window", "Close All")
    try expectAlternate(window, "Minimize", "Minimize All")
    try expectAlternate(window, "Zoom", "Zoom All")
    #expect(window.item(withTitle: "Minimize All")?.action == #selector(NSApplication.miniaturizeAll(_:)))
    #expect(window.item(withTitle: "Zoom All")?.action == NSSelectorFromString("zoomAll:"))
    #expect(window.item(withTitle: "Zoom All")?.target === target)
}

@MainActor
@Test func editMenuRoutesStandardTextActions() throws {
    let menu = MainMenuBuilder.make(target: NSObject())
    let edit = try #require(menu.item(withTitle: MainMenuBuilder.editMenuTitle)?.submenu)
    let expected: [(String, String, Selector)] = [
        ("Cut", "x", #selector(NSText.cut(_:))),
        ("Copy", "c", #selector(NSText.copy(_:))),
        ("Paste", "v", #selector(NSText.paste(_:))),
        ("Select All", "a", #selector(NSText.selectAll(_:))),
    ]
    for (title, key, action) in expected {
        let entry = try #require(edit.item(withTitle: title))
        #expect(entry.keyEquivalent == key)
        #expect(entry.action == action)
    }
}

@MainActor
@Test func performCloseClosesTheAboutWindow() throws {
    _ = NSApplication.shared
    let controller = AboutWindowController()
    let window = try #require(controller.window)
    #expect(window.styleMask.contains(.closable))
    window.orderFront(nil)
    #expect(window.isVisible)
    window.performClose(nil)
    #expect(!window.isVisible)
}

@MainActor
@Test func aboutWindowIsTitledAndFixedSize() throws {
    _ = NSApplication.shared
    let controller = AboutWindowController()
    let window = try #require(controller.window)
    #expect(window.title == "About Prism")
    #expect(!window.styleMask.contains(.resizable))
}

@MainActor
@Test func closeAllClosesEveryVisibleWindow() throws {
    _ = NSApplication.shared
    let first = try #require(AboutWindowController().window)
    let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                          styleMask: [.titled, .closable], backing: .buffered, defer: true)
    second.isReleasedWhenClosed = false
    first.orderFront(nil)
    second.orderFront(nil)
    AppDelegate().closeAll(nil)
    #expect(!first.isVisible)
    #expect(!second.isVisible)
}
