// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import Foundation
import PrismProtocol
import PrismTestSupport
import Testing
@testable import PrismApp

// Regression tests for the M10 review: the state file of test runs,
// "Don't Save" answers of cancelled closes, tab close callbacks, sturdy
// restoration (frames, levels, malformed files), clipboard snippets.

@MainActor
private func waitLoaded(_ controller: ComparisonWindowController) async {
    let deadline = Date(timeIntervalSinceNow: 90)
    try? await Task.sleep(for: .milliseconds(1))
    while (controller.isLoading || controller.blocksView.model == nil) && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private func pair(_ name: String) throws -> (TemporaryDirectory, URL, URL) {
    let directory = try TemporaryDirectory(prefix: "prism-m10-review-\(name)")
    let a = directory.url.appending(path: "a.txt"), b = directory.url.appending(path: "b.txt")
    try Data("1\n2\n3\n".utf8).write(to: a)
    try Data("1\nX\n3\n".utf8).write(to: b)
    return (directory, a, b)
}

/// A test run (PRISM_TESTING=1) without PRISM_STATE_PATH has no state
/// file: it never reads, deletes or overwrites the user's windows.
@MainActor
@Test func testRunsNeverUseTheUsersStateFile() {
    #expect(StateRestoration.fileURL(environment: [IPCEnvironment.testingVariable: "1"]) == nil)
    #expect(StateRestoration.fileURL(environment: [IPCEnvironment.testingVariable: "1",
                                                   StateRestoration.pathVariable: "/tmp/x.json"])?.path == "/tmp/x.json")
    let user = StateRestoration.fileURL(environment: [StateRestoration.pathVariable: "/tmp/ignored.json"])
    #expect(user?.path.hasSuffix("Library/Application Support/Prism/Windows.json") == true)
    // With no file, saving, taking and discarding do nothing.
    #expect(StateRestoration.take(from: nil).isEmpty)
    StateRestoration.discard(nil)
}

/// "Don't Save" holds only for the close it answered: a new edit, or a
/// cancelled close, makes the comparison ask again.
@MainActor
@Test func dontSaveDoesNotOutliveItsClose() async throws {
    _ = NSApplication.shared
    let (directory, a, b) = try pair("sticky")
    defer { directory.remove() }
    let host = DocumentWindowController()
    defer { host.close() }
    let tab = TextTab(a: a, b: b, key: "k1", title: nil)
    tab.controller.session.temporaryRoots = []
    host.insert(tab, at: 0)
    await waitLoaded(tab.controller)
    tab.controller.blocksView.selectChange(0, scroll: false)
    tab.controller.copyToRight(nil)
    await waitLoaded(tab.controller)
    #expect(tab.controller.session.isDirty)

    tab.controller.closingConfirmed = true
    DocumentWindowController.forgetCloseAnswers([tab])
    #expect(!tab.controller.closingConfirmed)

    tab.controller.closingConfirmed = true
    tab.controller.session.undoManager.undo()
    await waitLoaded(tab.controller)
    #expect(!tab.controller.closingConfirmed)
    // With no window on screen to ask on, unsaved changes keep it open.
    tab.controller.session.undoManager.redo()
    await waitLoaded(tab.controller)
    var answered: Bool?
    tab.controller.confirmClose { answered = $0 }
    #expect(answered == false)
}

/// Closing a tab fires its controller's onClose (prism --wait returns);
/// moving it to another window does not, closing that window does.
@MainActor
@Test func closingATabFiresOnCloseAndDetachingDoesNot() throws {
    _ = NSApplication.shared
    let (directory, a, b) = try pair("close")
    defer { directory.remove() }
    let host = DocumentWindowController()
    defer { host.close() }
    let tabs = (1...3).map { TextTab(a: a, b: b, key: "k\($0)", title: nil) }
    var closed: [String] = []
    for (index, tab) in tabs.enumerated() {
        tab.controller.onClose = { _ in closed.append("t\(index + 1)") }
        host.insert(tab, at: index)
    }
    host.closeTab(0)
    #expect(closed == ["t1"])
    let other = try #require(host.detachTab(1))
    #expect(closed == ["t1"])
    other.window?.close()
    #expect(closed == ["t1", "t3"])
}

@MainActor
@Test func restoredFramesStayOnScreen() {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
    let minimum = NSSize(width: 612, height: 470)
    #expect(StateRestoration.clampedFrame(NSRect(x: -99999, y: -99999, width: 1e9, height: -5),
                                          screens: [screen], minimum: minimum) == nil)
    #expect(StateRestoration.clampedFrame(NSRect(x: 5000, y: 5000, width: 800, height: 600),
                                          screens: [screen], minimum: minimum) == nil)
    let big = StateRestoration.clampedFrame(NSRect(x: -50, y: 10, width: 3000, height: 3000),
                                            screens: [screen], minimum: minimum)
    #expect(big == screen)
    let small = StateRestoration.clampedFrame(NSRect(x: 100, y: 100, width: 10, height: 10),
                                              screens: [screen], minimum: minimum)
    #expect(small?.size == minimum && small?.origin == NSPoint(x: 100, y: 100))
}

@Test func restoredLevelsStayBelowTheRoots() {
    #expect(StateRestoration.safeLevel("") == "")
    #expect(StateRestoration.safeLevel("src/util") == "src/util")
    for bad in ["..", "../..", "src/../..", "./src", "/etc", "src//x", "src/."] {
        #expect(StateRestoration.safeLevel(bad) == nil, "\(bad)")
    }
}

@MainActor
@Test func restorationSurvivesBadStates() throws {
    _ = NSApplication.shared
    let directory = try TemporaryDirectory(prefix: "prism-m10-review-restore")
    defer { directory.remove() }
    var paths: [String] = []
    for index in 0..<3 {
        let url = directory.url.appending(path: "f\(index).txt")
        try Data("x\(index)\n".utf8).write(to: url)
        paths.append(url.path)
    }
    let weird = TextTabState(files: [paths[0], "/nonexistent/zz", paths[1], paths[2]], nameOnly: [], a: -7, b: 99,
                             mode: "bogus", wrapsLines: true, ignoresWhitespace: true, shelfVisible: false, title: nil)
    let state = WindowState(frame: .init(NSRect(x: -99999, y: -99999, width: 1e9, height: -5)),
                            tabs: [.text(weird), .folder(FolderTabState(left: "/nope", right: "/nope2",
                                                                        relativePath: "../../etc"))],
                            selected: 42)
    let window = try #require(StateRestoration.makeWindow(state))
    defer { window.close() }
    #expect(window.tabs.count == 1)
    let frame = try #require(window.window?.frame)
    #expect(frame.width >= ComparisonWindowController.minimumContentSize.width && frame.width < 1e6)
    if let screen = NSScreen.screens.first?.visibleFrame { #expect(screen.intersects(frame)) }

    let file = directory.url.appending(path: "Windows.json")
    try Data("{\"old\":1}".utf8).write(to: file)
    #expect(StateRestoration.take(from: file).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: file.path))

    let folder = directory.url.appending(path: "nowdir")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let textState = TextTabState(files: [paths[0], folder.path], nameOnly: [false, false], a: 0, b: 1, mode: "blocks",
                                 wrapsLines: false, ignoresWhitespace: false, shelfVisible: false, title: nil)
    #expect(StateRestoration.makeWindow(WindowState(frame: .init(.zero), tabs: [.text(textState)], selected: 0)) == nil)
}

/// A saved level that is gone, or that would leave the roots, comes back
/// as the roots.
@MainActor
@Test func restoredFolderLevelsFallBackToTheRoots() throws {
    _ = NSApplication.shared
    let directory = try TemporaryDirectory(prefix: "prism-m10-review-level")
    defer { directory.remove() }
    let left = directory.url.appending(path: "L"), right = directory.url.appending(path: "R")
    for root in [left, right] {
        try FileManager.default.createDirectory(at: root.appending(path: "sub"), withIntermediateDirectories: true)
    }
    for (level, expected) in [("gone/deeper", ""), ("../..", ""), ("sub", "sub")] {
        let state = WindowState(frame: .init(NSRect(x: 0, y: 0, width: 800, height: 600)),
                                tabs: [.folder(FolderTabState(left: left.path, right: right.path, relativePath: level))],
                                selected: 0)
        let window = try #require(StateRestoration.makeWindow(state))
        #expect((window.tabs.first as? FolderTab)?.scope.relativePath == expected, "\(level)")
        window.close()
    }
}

/// The state holds paths and view settings, never file contents.
@MainActor
@Test func savedStateHoldsPathsOnly() throws {
    _ = NSApplication.shared
    let (directory, a, b) = try pair("written")
    defer { directory.remove() }
    let host = DocumentWindowController()
    defer { host.close() }
    host.insert(TextTab(a: a, b: b, key: "k", title: nil), at: 0)
    let file = directory.url.appending(path: "W.json")
    let saved = StateRestoration.save([host], to: file)
    #expect(saved.count == 1)
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(!text.contains("X\\n") && text.contains("a.txt"))
}

@MainActor
@Test func clipboardSnippetsAreCleanedUnlessKept() throws {
    let directory = try TemporaryDirectory(prefix: "prism-m10-review-clip")
    defer { directory.remove() }
    let folder = directory.url.appending(path: "Prism-Clipboard", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let kept = folder.appending(path: "Clipboard.txt"), dropped = folder.appending(path: "Clipboard 2.txt")
    for url in [kept, dropped] { try Data("x".utf8).write(to: url) }
    ClipboardSnippets.cleanUp(keeping: [kept.path(percentEncoded: false)], in: folder)
    #expect(FileManager.default.fileExists(atPath: kept.path) && !FileManager.default.fileExists(atPath: dropped.path))
    ClipboardSnippets.cleanUp(keeping: [], in: folder)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
}
