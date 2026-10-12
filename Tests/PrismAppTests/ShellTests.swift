// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import Darwin
import DiffCore
import Foundation
import PrismTestSupport
import Testing
@testable import PrismApp

// M10: tabs, the file shelf, the launch window, breadcrumbs, menus and
// state restoration.

@MainActor
private func spin(until condition: () -> Bool, timeout: TimeInterval = 90) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// `count` small text files that all differ, in a fresh folder.
private func textFiles(_ count: Int, prefix: String = "shelf") throws -> (TemporaryDirectory, [URL]) {
    let directory = try TemporaryDirectory(prefix: "prism-m10-\(prefix)")
    var urls: [URL] = []
    for index in 0..<count {
        let url = directory.url.appending(path: "file\(index).txt")
        let lines = (0..<6).map { $0 == index ? "line \($0) changed in \(index)" : "line \($0)" }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        urls.append(url)
    }
    return (directory, urls)
}

/// A copy of the folder fixtures with fixed times (README.md unchanged).
private func folderFixture() throws -> TemporaryDirectory {
    let directory = try TemporaryDirectory(prefix: "prism-m10-folders")
    let source = Corpus.directory.appending(path: "fixtures/folders", directoryHint: .isDirectory)
    for side in ["left", "right"] {
        let target = directory.url.appending(path: side, directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source.appending(path: side), to: target)
        let root = target.path(percentEncoded: false)
        var items = FileManager.default.subpaths(atPath: root) ?? []
        items.sort { $0.count > $1.count }
        for item in items + [""] {
            let seconds = item == "README.md" ? 1_577_836_800 : 1_791_729_989
            var times = [timespec(tv_sec: seconds, tv_nsec: 0), timespec(tv_sec: seconds, tv_nsec: 0)]
            _ = utimensat(AT_FDCWD, item.isEmpty ? root : root + "/" + item, &times, AT_SYMLINK_NOFOLLOW)
        }
    }
    return directory
}

private func entries(_ urls: [URL]) -> [ShelfEntry] { urls.map { ShelfEntry(url: $0) } }

// MARK: - shelf model

@Test func shelfStepsBThroughTheFilesSkippingA() {
    let files = (0..<4).map { ShelfEntry(url: URL(filePath: "/tmp/f\($0)")) }
    var model = ShelfModel(files: files)
    #expect(model.a == 0 && model.b == 1)
    var seen: [Int] = []
    for _ in 0..<4 {
        let moved = model.stepB(1)
        #expect(moved)
        seen.append(model.b)
    }
    #expect(seen == [2, 3, 1, 2])
    var ok = model.stepB(-1)
    #expect(ok && model.b == 1)
    ok = model.stepA(1)
    #expect(ok && model.a == 2)
    ok = model.stepA(-1)
    #expect(ok && model.a == 0)
    ok = model.stepBoth(1)
    #expect(ok && model.a == 1 && model.b == 2)
    ok = model.stepBoth(-1)
    #expect(ok && model.a == 0 && model.b == 1)
}

@Test func shelfWithTwoFilesOnlySwapsBoth() {
    var model = ShelfModel(files: [ShelfEntry(url: URL(filePath: "/a")), ShelfEntry(url: URL(filePath: "/b"))])
    let b = model.stepB(1), a = model.stepA(1)
    #expect(!b && !a)
    let both = model.stepBoth(1)
    #expect(both && model.a == 1 && model.b == 0)
    let removed = model.remove(0)
    #expect(!removed)
}

@Test func shelfSetAddRemoveKeepAAndBDistinct() {
    var model = ShelfModel(files: (0..<3).map { ShelfEntry(url: URL(filePath: "/f\($0)")) })
    model.setB(0)
    #expect(model.a == 1 && model.b == 0)
    model.setA(0)
    #expect(model.a == 0 && model.b == 1)
    model.add([ShelfEntry(url: URL(filePath: "/new"))], makeB: true)
    #expect(model.count == 4 && model.b == 3 && model.entryB?.url.lastPathComponent == "new")
    var removed = model.remove(3)
    #expect(removed)
    #expect(model.count == 3 && model.a != model.b)
    removed = model.remove(0)
    #expect(removed)
    #expect(model.count == 2 && Set([model.a, model.b]) == [0, 1])
}

// MARK: - shelf in a comparison

/// Shelf with 4 files: → cycles B through the files in order, and the
/// comparison updates each time.
@MainActor
@Test func shelfNextBUpdatesTheComparison() async throws {
    _ = NSApplication.shared
    let (directory, urls) = try textFiles(4)
    defer { directory.remove() }
    let controller = ComparisonWindowController(a: urls[0], b: urls[1])
    defer { controller.close() }
    controller.setShelfFiles(entries(urls), a: 0, b: 1)
    #expect(controller.isShelfVisible)
    #expect(controller.fileCount == 4)
    #expect(controller.shelfView.cards.map(\.letterField.stringValue) == ["A", "B", "", ""])
    #expect(await spin { controller.blocksView.model != nil && !controller.isLoading })
    var order: [String] = []
    for _ in 0..<3 {
        controller.selectNextB(nil)
        let index = Int(controller.urlB.deletingPathExtension().lastPathComponent.dropFirst(4)) ?? -1
        // The comparison shows the new B: its line `index` is the changed one.
        #expect(await spin {
            !controller.isLoading && controller.blocksView.model?.side(.b).text(ofLine: index) == "line \(index) changed in \(index)"
        })
        order.append(controller.urlB.lastPathComponent)
        #expect(controller.title == "file0.txt | \(controller.urlB.lastPathComponent)")
        // file0 and fileN differ on lines 0 and N.
        #expect((controller.blocksView.model?.changeCount ?? 0) >= 1)
    }
    #expect(order == ["file2.txt", "file3.txt", "file1.txt"])
    controller.selectNextA(nil)
    #expect(controller.urlA.lastPathComponent == "file2.txt")
    controller.toggleFileShelf(nil)
    #expect(!controller.isShelfVisible)
}

@MainActor
@Test func shelfItemsValidateByFileCount() throws {
    _ = NSApplication.shared
    let (directory, urls) = try textFiles(3)
    defer { directory.remove() }
    let controller = ComparisonWindowController(a: urls[0], b: urls[1])
    defer { controller.close() }
    func enabled(_ action: Selector) -> Bool { controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")) }
    #expect(!enabled(#selector(ComparisonWindowController.selectNextB(_:))))
    #expect(enabled(#selector(ComparisonWindowController.selectNextAAndB(_:))))
    #expect(enabled(#selector(ComparisonWindowController.toggleFileShelf(_:))))
    controller.setShelfFiles(entries(urls), a: 0, b: 1)
    #expect(enabled(#selector(ComparisonWindowController.selectNextB(_:))))
    #expect(enabled(#selector(ComparisonWindowController.selectPreviousA(_:))))
}

// MARK: - edit menu arrows

/// A disabled menu item still swallows its key: the Edit menu lets bare
/// arrows through unless the shelf can use them.
@MainActor
@Test func editMenuLetsArrowsThroughUnlessTheShelfUsesThem() throws {
    _ = NSApplication.shared
    let menu = MainMenuBuilder.make(target: NSObject())
    let edit = try #require(menu.item(withTitle: MainMenuBuilder.editMenuTitle)?.submenu as? ShellEditMenu)
    let right = MainMenuBuilder.rightArrow
    func key(_ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags.union([.numericPad, .function]),
                         timestamp: 0, windowNumber: 0, context: nil, characters: right,
                         charactersIgnoringModifiers: right, isARepeat: false, keyCode: 124)!
    }
    #expect(ShellEditMenu.arrowItem(in: edit, for: key([]))?.title == "Select Next B")
    #expect(ShellEditMenu.arrowItem(in: edit, for: key(.option))?.title == "Select Next A")
    #expect(ShellEditMenu.arrowItem(in: edit, for: key(.command)) == nil)
    // Nothing handles the shelf items here: the key is not consumed.
    #expect(!edit.performKeyEquivalent(with: key([])))
    #expect(!edit.performKeyEquivalent(with: key(.option)))
}

// MARK: - tabs

@MainActor
@Test func tabsSelectReorderCloseAndDetach() async throws {
    _ = NSApplication.shared
    let (directory, urls) = try textFiles(4, prefix: "tabs")
    defer { directory.remove() }
    RegisteredWindows.install()
    let controller = DocumentWindowController()
    defer { controller.close() }
    for index in 0..<3 {
        controller.insert(TextTab(a: urls[index], b: urls[index + 1], key: "t\(index)", title: nil), at: index)
    }
    #expect(controller.tabs.map(\.title) == ["file0.txt | file1.txt", "file1.txt | file2.txt", "file2.txt | file3.txt"])
    #expect(controller.selectedIndex == 2)
    #expect(controller.tabStrip.items.count == 3)
    #expect(controller.tabStrip.items.map(\.titleField.stringValue) == controller.tabs.map(\.title))
    controller.selectNextTab(nil)
    #expect(controller.selectedIndex == 0)
    controller.selectPreviousTab(nil)
    #expect(controller.selectedIndex == 2)
    let item = NSMenuItem(title: "", action: #selector(DocumentWindowController.selectNextTab(_:)), keyEquivalent: "")
    #expect(controller.validateMenuItem(item))

    controller.moveTab(from: 2, to: 0)
    #expect(controller.tabs.first?.title == "file2.txt | file3.txt" && controller.selectedIndex == 0)

    // Command-W closes the selected tab, not the window.
    controller.closeComparison(nil)
    #expect(controller.tabs.count == 2)

    // Drag out: a new window takes the tab, the source keeps the rest.
    let moved = controller.tabs[1].title
    let other = try #require(controller.detachTab(1))
    defer { other.close() }
    #expect(other.tabs.map(\.title) == [moved])
    #expect(controller.tabs.count == 1)
    #expect(RegisteredWindows.contains(other))
    let text = try #require(other.tabs.first as? TextTab)
    #expect(text.controller.hostWindow === other.window)
    #expect(!controller.validateMenuItem(item))
    // The only tab cannot be dragged out.
    #expect(controller.detachTab(0) == nil)
}

@MainActor
@Test func tabStripOverflowAndDropGeometry() {
    #expect(DocumentTabStrip.fitting(count: 3, width: 1000) == (3, false))
    let fit = DocumentTabStrip.fitting(count: 12, width: 700)
    #expect(fit.overflow && fit.visible < 12 && fit.visible >= 1)
    #expect(DocumentTabStrip.visibleRange(count: 12, visible: 4, selected: 1) == 0..<4)
    #expect(DocumentTabStrip.visibleRange(count: 12, visible: 4, selected: 9) == 6..<10)
    #expect(DocumentTabStrip.dropIndex(centerX: 10, visible: 0..<4, width: 400) == 0)
    #expect(DocumentTabStrip.dropIndex(centerX: 390, visible: 0..<4, width: 400) == 3)
    #expect(DocumentTabStrip.isDetach(point: NSPoint(x: 5, y: 80), stripHeight: 24))
    #expect(!DocumentTabStrip.isDetach(point: NSPoint(x: 5, y: 30), stripHeight: 24))

    let strip = DocumentTabStrip()
    strip.frame = NSRect(x: 0, y: 0, width: 500, height: 24)
    strip.setTabs((0..<8).map { DocumentTabStrip.Tab(title: "tab \($0)", symbol: "doc.text", count: 2) }, selected: 0)
    strip.layoutSubtreeIfNeeded()
    #expect(!strip.overflowButton.isHidden)
    let hidden = strip.overflowMenu().items.map(\.title)
    #expect(!hidden.isEmpty && !hidden.contains("tab 0"))
    #expect(strip.tabMenu(for: 1).items.map(\.title).contains("Move Tab to New Window"))
}

// MARK: - launch window

@MainActor
@Test func launchWindowTakesOneFileThenTheSecond() async throws {
    _ = NSApplication.shared
    let (directory, urls) = try textFiles(2, prefix: "launch")
    defer { directory.remove() }
    let controller = DocumentWindowController()
    defer { controller.close() }
    let launch = LaunchTab()
    controller.insert(launch, at: 0)
    let window = try #require(controller.window)
    #expect(controller.isLaunchMode)
    #expect(window.contentLayoutRect.size == DocumentWindowController.launchSize)
    #expect(!window.styleMask.contains(.resizable))
    #expect(launch.dropView.caption.stringValue == LaunchDropView.dropCaption)

    launch.receive([urls[0]])
    #expect(controller.tabs.first === launch && launch.pending == [urls[0]])
    #expect(launch.dropView.caption.stringValue != LaunchDropView.dropCaption)
    launch.receive([urls[1]])
    let text = try #require(controller.tabs.first as? TextTab)
    #expect(text.title == "file0.txt | file1.txt")
    #expect(!controller.isLaunchMode && window.styleMask.contains(.resizable))
    #expect(await spin { text.controller.blocksView.model != nil })

    // New Tab adds an empty tab; the window stays a document window.
    controller.newTab(nil)
    #expect(controller.tabs.count == 2 && controller.selectedTab is LaunchTab && !controller.isLaunchMode)
}

@MainActor
@Test func pasteToComparisonUsesTheClipboardText() async throws {
    _ = NSApplication.shared
    let board = TestPasteboard.install()
    board.clearContents()
    board.setString("one\ntwo\n", forType: .string)
    let controller = DocumentWindowController()
    defer { controller.close() }
    let launch = LaunchTab()
    controller.insert(launch, at: 0)
    controller.pasteToComparison(nil)
    #expect(launch.pending.count == 1)
    board.clearContents()
    board.setString("one\nTWO\n", forType: .string)
    controller.pasteToComparison(nil)
    let text = try #require(controller.tabs.first as? TextTab)
    #expect(await spin { text.controller.blocksView.model != nil })
    #expect(text.controller.blocksView.model?.changeCount == 1)
    // A third paste goes on the shelf as B.
    board.clearContents()
    board.setString("zero\n", forType: .string)
    controller.pasteToComparison(nil)
    #expect(text.controller.fileCount == 3 && text.controller.shelf.b == 2 && text.controller.isShelfVisible)
    #expect(text.controller.pathDisplay.b == .nameOnly)
}

// MARK: - restoration

/// Quit with 3 tabs open, relaunch: the 3 tabs come back with their view
/// modes.
@MainActor
@Test func windowStateBringsBackTabsAndModes() async throws {
    _ = NSApplication.shared
    let (directory, urls) = try textFiles(4, prefix: "restore")
    defer { directory.remove() }
    let fixtures = Corpus.directory.appending(path: "fixtures/folders", directoryHint: .isDirectory)
    let controller = DocumentWindowController()
    defer { controller.close() }
    let modes: [ViewMode] = [.blocks, .fluid, .unified]
    for (index, mode) in modes.enumerated() {
        let tab = TextTab(a: urls[index], b: urls[index + 1], key: "r\(index)", title: nil)
        tab.controller.setMode(mode, remember: false)
        controller.insert(tab, at: index)
    }
    let folder = FolderDocument(left: fixtures.appending(path: "left"), right: fixtures.appending(path: "right"))
    controller.insert(folder.makeTab(relativePath: "src"), at: 3)
    controller.selectTab(1)
    let state = try #require(controller.restorationState)
    #expect(state.tabs.count == 4 && state.selected == 1)

    let file = directory.url.appending(path: "Windows.json")
    StateRestoration.save([controller], to: file)
    let loaded = StateRestoration.take(from: file)
    #expect(loaded == [state])
    #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))

    let restored = try #require(StateRestoration.makeWindow(loaded[0]))
    defer { restored.close() }
    #expect(restored.tabs.map(\.title) == controller.tabs.map(\.title))
    #expect(restored.selectedIndex == 1)
    let restoredModes = restored.tabs.compactMap { ($0 as? TextTab)?.controller.blocksView.mode }
    #expect(restoredModes == modes)
    #expect((restored.tabs[3] as? FolderTab)?.scope.relativePath == "src")
}

@MainActor
@Test func restorationSkipsMissingFilesAndChangesets() throws {
    let state = WindowState(frame: .init(NSRect(x: 0, y: 0, width: 800, height: 600)),
                            tabs: [.text(TextTabState(files: ["/nonexistent/a", "/nonexistent/b"], nameOnly: [false, false],
                                                      a: 0, b: 1, mode: "fluid", wrapsLines: false,
                                                      ignoresWhitespace: false, shelfVisible: false, title: nil))],
                            selected: 0)
    #expect(StateRestoration.makeWindow(state) == nil)
    let data = try StateRestoration.encode([state])
    #expect(try StateRestoration.decode(data) == [state])
}

// MARK: - recent

@MainActor
@Test func recentComparisonsAreTitledAAndB() throws {
    let suite = "prism-m10-recent-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let recent = RecentComparisons()
    recent.defaults = defaults
    recent.note([URL(filePath: "/x/a.swift"), URL(filePath: "/x/b.swift")])
    recent.note([URL(filePath: "/s/README.md"), URL(filePath: "/l/README.md")])
    recent.note([URL(filePath: "/x/a.swift"), URL(filePath: "/x/b.swift")])
    #expect(recent.entries.count == 2)
    #expect(RecentComparisons.title(for: recent.entries[0]) == "a.swift | b.swift")
    #expect(RecentComparisons.title(for: recent.entries[1]) == "README.md (s) | README.md (l)")
    let menu = NSMenu(title: MainMenuBuilder.openRecentTitle)
    RecentMenu.fill(menu, entries: recent.entries, target: nil)
    #expect(menu.items.map(\.title) == ["a.swift | b.swift", "README.md (s) | README.md (l)", "", "Clear Menu"])
    recent.clear()
    #expect(recent.entries.isEmpty)
}

// MARK: - breadcrumbs

@MainActor
@Test func breadcrumbsNameOnlyTheLastTwoComponents() throws {
    let file = Corpus.fixture("text/a.swift")
    let parts = BreadcrumbView.components(of: file)
    #expect(parts.first?.path(percentEncoded: false) == "/")
    #expect(parts.last?.lastPathComponent == "a.swift")
    let view = BreadcrumbView(frame: NSRect(x: 0, y: 0, width: 2000, height: 22))
    view.show(file, display: .path)
    view.layoutSubtreeIfNeeded()
    let titles = view.shownTitles
    #expect(titles.count == parts.count)
    #expect(titles.suffix(2).allSatisfy { !$0.isEmpty })
    #expect(titles.dropLast(2).allSatisfy { $0.isEmpty })
    #expect(titles.last?.hasPrefix("a.swift") == true)

    // Narrow: leading components fold into the overflow.
    view.frame.size.width = 160
    view.layoutSubtreeIfNeeded()
    #expect(view.collapsed > 0)

    // The file's menu lists its siblings (b.swift among them) and the
    // Finder actions.
    let menu = view.menu(forComponent: parts.count - 1)
    let titlesInMenu = menu.items.map(\.title)
    #expect(titlesInMenu.contains("b.swift"))
    #expect(titlesInMenu.contains("Reveal in Finder") && titlesInMenu.contains("Copy Path")
        && titlesInMenu.contains("Open With"))
    #expect(menu.items.first { $0.title == "a.swift" }?.state == .on)
    // A folder component offers Terminal, and its siblings carry the rest
    // of the path (only those that have it can be chosen).
    let folderMenu = view.menu(forComponent: parts.count - 2)
    #expect(folderMenu.items.contains { $0.title == "Open in Terminal" })
}

@MainActor
@Test func choosingASiblingInThePathBarReplacesThatSide() async throws {
    _ = NSApplication.shared
    let (directory, urls) = try textFiles(3, prefix: "crumbs")
    defer { directory.remove() }
    let controller = ComparisonWindowController(a: urls[0], b: urls[1])
    defer { controller.close() }
    controller.pathBar.onChoose?(.b, urls[2])
    #expect(controller.urlB == urls[2] && controller.shelf.entryB?.url == urls[2])
    #expect(controller.title == "file0.txt | file2.txt")
}

// MARK: - menus

/// Every item and shortcut of the reference menus (our list, from the
/// observations), in each menu.
@MainActor
@Test func menusHaveTheReferenceShortcuts() throws {
    let menu = MainMenuBuilder.make(target: NSObject())
    func find(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let sub = item.submenu, let found = find(title, in: sub) { return found }
        }
        return nil
    }
    let expected: [(String, String)] = [
        ("Settings\u{2026}", "[0:,:44]"), ("Hide Prism", "[0:H:72]"), ("Hide Others", "[2:H:72]"),
        ("Quit Prism", "[0:Q:81]"), ("Quit and Keep Windows", "[2:Q:81]"),
        ("New Window", "[0:N:78]"), ("New Tab", "[0:T:84]"), ("New from Clipboard", "[1:N:78]"),
        ("Open...", "[0:O:79]"), ("Close Window", "[1:W:87]"), ("Close All", "[3:W:87]"),
        ("Close Comparison", "[0:W:87]"), ("Save", "[0:S:83]"), ("Save All", "[1:S:83]"),
        ("Undo", "[0:Z:90]"), ("Redo", "[1:Z:90]"), ("Paste to Comparison", "[2:V:86]"),
        ("Swap A & B", "[0:\\:92]"), ("Select Next A", "[10:\u{F703}:63235]"),
        ("Select Previous A", "[10:\u{F702}:63234]"), ("Select Next B", "[8:\u{F703}:63235]"),
        ("Select Previous B", "[8:\u{F702}:63234]"), ("Find\u{2026}", "[0:F:70]"), ("Jump to Selection", "[0:J:74]"),
        ("Show Spelling and Grammar", "[0:::58]"), ("Check Spelling", "[0:;:59]"),
        ("Toggle File Shelf", "[0:/:47]"), ("Enter Full Screen", "[24:F:70]"),
        ("Select Previous File", "[1:\u{F700}:63232]"), ("Select Next File", "[1:\u{F701}:63233]"),
        ("Blocks", "[0:1:49]"), ("Previous Change", "[0:\u{F700}:63232]"),
        ("Previous Conflict", "[2:\u{F700}:63232]"), ("Next Conflict", "[2:\u{F701}:63233]"),
        ("Increase Text Size", "[0:+:43]"), ("Wrap Lines", "[1:K:75]"), ("Ignore Whitespace", "[1:':39]"),
        ("Copy to Right", "[0:\u{F703}:63235]"), ("Reset Selection", "[2:\u{08}:8]"),
        ("Keep Both (Right then Left)", "[2:\u{F702}:63234]"), ("Start Copying Files", "[0:\n:10]"),
        ("Minimize", "[0:M:77]"), ("Minimize All", "[2:M:77]"),
        ("Select Next Tab", "[1:]:93]"), ("Select Previous Tab", "[1:[:91]"), ("Prism Help", "[0:?:63]"),
    ]
    for (title, shortcut) in expected {
        let item = try #require(find(title, in: menu), "missing \(title)")
        #expect(MenuDump.shortcut(item) == " " + shortcut, "\(title)")
    }
    for title in ["Select Next A & B", "Select Previous A & B", "Revert to Saved", "Zoom", "Zoom All",
                  "Bring All to Front", "Prism Website", "Getting Started", "Send Feedback...", "Start Speaking",
                  "Stop Speaking", "Check Spelling While Typing", "Open Recent...", "Open Selection"] {
        #expect(find(title, in: menu) != nil, "missing \(title)")
    }
}

@MainActor
@Test func viewMenuShowsTheItemsOfTheKindInFront() throws {
    let menu = MainMenuBuilder.make(target: NSObject())
    let view = try #require(menu.item(withTitle: MainMenuBuilder.viewMenuTitle)?.submenu)
    func visible() -> [String] { view.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "-" : $0.title } }
    ViewMenuContext.update(view) { ComparisonWindowController.instancesRespond(to: $0) }
    #expect(visible() == ["Toggle File Shelf", "Enter Full Screen", "-", "Select Previous File", "Select Next File", "-",
                          "Blocks", "Fluid", "Unified", "-", "Previous Change", "Next Change", "-",
                          "Previous Conflict", "Next Conflict", "-", "Increase Text Size", "Decrease Text Size", "-",
                          "Wrap Lines", "Ignore Whitespace"])
    ViewMenuContext.update(view) { FolderScopeController.instancesRespond(to: $0) }
    #expect(visible() == ["Toggle File Shelf", "Enter Full Screen", "-", "Select Previous File", "Select Next File", "-",
                          "Previous Change", "Next Change", "-", "Open Selection"])
}

/// The menus as the accessibility API would list them, with a text and a
/// folder comparison in front. With PRISM_MENU_DUMP_DIR set, the listings
/// are written there (menus-text-2up.txt, menus-folder.txt) for the
/// acceptance script to compare with the reference.
@MainActor
@Test func menuDumpsForTextAndFolderContexts() async throws {
    _ = NSApplication.shared
    let app = AppDelegate()
    let savedDelegate = NSApp.delegate
    NSApp.delegate = app
    defer { NSApp.delegate = savedDelegate }
    let board = TestPasteboard.install()
    board.clearContents()
    board.setString("clipboard text\n", forType: .string)
    let output = ProcessInfo.processInfo.environment["PRISM_MENU_DUMP_DIR"].map { URL(filePath: $0) }

    // Text: a.swift | b.swift in Fluid, an inserted line selected.
    let text = DocumentWindowController()
    defer { text.close() }
    let tab = TextTab(a: Corpus.fixture("text/a.swift"), b: Corpus.fixture("text/b.swift"), key: "dump", title: nil)
    tab.controller.setMode(.fluid, remember: false)
    text.insert(tab, at: 0)
    #expect(await spin { tab.controller.blocksView.model != nil && !tab.controller.isLoading })
    let model = try #require(tab.controller.blocksView.model)
    let insert = try #require(model.layout.changes.firstIndex { model.layout.blocks[$0].isInsert })
    tab.controller.blocksView.selectChange(insert, scroll: false)
    let window = try #require(text.window)
    window.makeFirstResponder(tab.controller.blocksView)
    let textDump = MenuDump.dump(MainMenuBuilder.make(target: app), window: window)
    #expect(textDump.contains("- Fluid [0:2:50] \u{2713}"))
    #expect(textDump.contains("- Copy to Right [0:\u{F703}:63235]\n"))
    #expect(textDump.contains("- Keep Both (Left then Right) [2:\u{F703}:63235] (disabled)"))
    #expect(textDump.contains("- Select Next Tab [1:]:93] (disabled)"))
    #expect(textDump.contains("- Select Next B [8:\u{F703}:63235] (disabled)"))
    #expect(textDump.contains("- Select Next A & B\n"))
    #expect(textDump.contains("- Paste [0:V:86]\n"))
    #expect(!textDump.contains("Open Selection"))
    #expect(!textDump.contains("Start Copying Files"))

    // Folder: the fixture roots, README.md selected.
    let fixture = try folderFixture()
    defer { fixture.remove() }
    let folder = DocumentWindowController(left: fixture.url.appending(path: "left"), right: fixture.url.appending(path: "right"))
    defer { folder.close() }
    let scope = try #require((folder.tabs.first as? FolderTab)?.scope)
    #expect(await spin { scope.level?.isComplete == true })
    scope.select(name: "README.md")
    let folderWindow = try #require(folder.window)
    folderWindow.makeFirstResponder(scope.view.tableA)
    // Return opens the selection while the folder window is key.
    let folderMenu = MainMenuBuilder.make(target: app)
    let savedMenu = NSApp.mainMenu
    NSApp.mainMenu = folderMenu
    DocumentWindowController.bindReturn(true)
    let folderDump = MenuDump.dump(folderMenu, window: folderWindow)
    DocumentWindowController.bindReturn(false)
    NSApp.mainMenu = savedMenu
    #expect(folderDump.contains("- Open Selection"))
    #expect(!folderDump.contains("- Blocks"))
    #expect(folderDump.contains("- Copy to Right [0:\u{F703}:63235] (disabled)"))
    #expect(folderDump.contains("- Paste [0:V:86] (disabled)"))
    #expect(folderDump.contains("- Find\u{2026} [0:F:70] (disabled)"))
    #expect(folderDump.contains("- Toggle File Shelf [0:/:47]\n"))

    if let output {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data(textDump.utf8).write(to: output.appending(path: "menus-text-2up.txt"))
        try Data(folderDump.utf8).write(to: output.appending(path: "menus-folder.txt"))
    }
}

/// One private pasteboard for every test that pastes, installed once and
/// never swapped back: tests run concurrently, and swapping the shared
/// pasteboard per test let one test read another's text across an await.
/// Each test sets the contents right before the synchronous read.
@MainActor
enum TestPasteboard {
    private static let board = NSPasteboard(name: NSPasteboard.Name("prism-tests-\(getpid())"))

    static func install() -> NSPasteboard {
        ClipboardSnippets.pasteboard = board
        return board
    }
}
