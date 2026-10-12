// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import DiffCore
import Foundation
import PrismProtocol
import PrismTestSupport
import Testing
@testable import PrismApp

// Regressions found by the final GUI batch on the integrated branch (m07 +
// m10), checked here without any window on screen: per-tab layouts and
// their routing, Quit and Keep Windows writing its state file, Move Tab to
// New Window through accessibility, the jump to a change in a tab, the
// selection probe measured in the window the tab lives in, and settings
// kept apart from the owner's under PRISM_TESTING.

@MainActor
private func spin(until condition: () -> Bool, timeout: TimeInterval = 90) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func textFiles(_ count: Int) throws -> (TemporaryDirectory, [URL]) {
    let directory = try TemporaryDirectory(prefix: "prism-shellfix")
    var urls: [URL] = []
    for index in 0..<count {
        let url = directory.url.appending(path: "file\(index).txt")
        let lines = (0..<6).map { $0 == index ? "line \($0) changed in \(index)" : "line \($0)" }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        urls.append(url)
    }
    return (directory, urls)
}

/// A window with three text tabs (file0|file1, file1|file2, file2|file3).
@MainActor
private func threeTabs(_ urls: [URL]) async -> DocumentWindowController {
    _ = NSApplication.shared
    let controller = DocumentWindowController()
    for index in 0..<3 {
        let tab = TextTab(a: urls[index], b: urls[index + 1], key: "t\(index)", title: nil)
        tab.controller.setMode(.blocks, remember: false)
        controller.insert(tab, at: index)
    }
    _ = await spin { controller.textTabs.allSatisfy { !$0.controller.isLoading && $0.controller.blocksView.model != nil } }
    return controller
}

// MARK: 2. per-tab layout and its routing

@MainActor
@Test func viewMenuLayoutGoesToTheSelectedTabAndIsRecordedPerTab() async throws {
    let (directory, urls) = try textFiles(4)
    defer { directory.remove() }
    let controller = await threeTabs(urls)
    defer { controller.close() }
    let window = try #require(controller.window)
    let actions = [#selector(ComparisonWindowController.showBlocksLayout(_:)),
                   #selector(ComparisonWindowController.showFluidLayout(_:)),
                   #selector(ComparisonWindowController.showUnifiedLayout(_:))]
    for (index, action) in actions.enumerated() {
        controller.selectTab(index)
        // What a View-menu press reaches while Prism is in the background.
        let target = PrismApplication.target(forAction: action, in: window) as? ComparisonWindowController
        #expect(target === controller.textTabs[index].controller, "tab \(index)")
        _ = target?.perform(action, with: nil)
    }
    #expect(controller.textTabs.map(\.controller.blocksView.mode) == [.blocks, .fluid, .unified])
    // A layout change re-records the tabs (the windowTabs perf event).
    #expect(controller.textTabs.allSatisfy { $0.controller.onModeChange != nil })
    // The modes survive switching tabs.
    controller.selectTab(0)
    controller.selectTab(2)
    #expect(controller.textTabs.map(\.controller.blocksView.mode) == [.blocks, .fluid, .unified])
}

// MARK: 1. Quit and Keep Windows writes its state

@MainActor
@Test func quitAndKeepWindowsWritesTheStateFileWithEveryTabAndMode() async throws {
    let (directory, urls) = try textFiles(4)
    defer { directory.remove() }
    let controller = await threeTabs(urls)
    defer { controller.close() }
    controller.textTabs[1].controller.setMode(.fluid, remember: false)
    controller.textTabs[2].controller.setMode(.unified, remember: false)
    let file = directory.url.appending(path: "state/state.json")
    // Under PRISM_TESTING the file is the one PRISM_STATE_PATH names.
    #expect(StateRestoration.fileURL(environment: [IPCEnvironment.testingVariable: "1",
                                                   StateRestoration.pathVariable: file.path]) == file)
    let saved = AppDelegate.saveWindows([controller], keep: true, to: file)
    #expect(saved.count == 1 && saved[0].tabs.count == 3)
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains("\"mode\" : \"unified\"") && text.contains("\"mode\" : \"fluid\""))
    let restored = try #require(StateRestoration.makeWindow(StateRestoration.take(from: file)[0]))
    defer { restored.close() }
    #expect(restored.textTabs.map(\.controller.blocksView.mode) == [.blocks, .fluid, .unified])
    // A plain quit removes the state.
    AppDelegate.saveWindows([controller], keep: true, to: file)
    AppDelegate.saveWindows([controller], keep: false, to: file)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

// MARK: 3. Move Tab to New Window through accessibility

@MainActor
@Test func moveTabToNewWindowAccessibilityActionDetachesTheTab() async throws {
    let (directory, urls) = try textFiles(4)
    defer { directory.remove() }
    RegisteredWindows.install()
    let controller = await threeTabs(urls)
    defer { controller.close() }
    let item = controller.tabStrip.items[2]
    #expect(item.accessibilityIdentifier() == "prism.tab.2")
    let action = try #require(item.accessibilityCustomActions()?.first { $0.name == "Move Tab to New Window" })
    let moved = controller.tabs[2].title
    #expect(action.handler?() == true)
    #expect(controller.tabs.count == 2)
    // Other tests run concurrently and open windows too: find this one by
    // its tab rather than taking the last window registered.
    let other = try #require(RegisteredWindows.find { $0 !== controller && $0.tabs.map(\.title) == [moved] })
    defer { other.close() }
    #expect(other.tabs.map(\.title) == [moved])
    // The menu command does the same for the selected tab.
    controller.selectTab(1)
    let second = controller.tabs[1].title
    controller.moveTabToNewWindow(nil)
    #expect(controller.tabs.count == 1)
    let third = RegisteredWindows.find { $0 !== controller && $0.tabs.map(\.title) == [second] }
    #expect(third != nil)
    third?.close()
}

// MARK: 4. the jump to a change in a tab, and the selection probe

@MainActor
@Test func jumpToAChangeInATabScrollsBothPanesTogether() async throws {
    _ = NSApplication.shared
    let controller = DocumentWindowController()
    defer { controller.close() }
    let tab = TextTab(a: Corpus.fixture("text/big_a.txt"), b: Corpus.fixture("text/big_b.txt"),
                      key: "big", title: nil, initialChange: 473)
    tab.controller.setMode(.blocks, remember: false)
    controller.insert(tab, at: 0)
    controller.window?.contentView?.layoutSubtreeIfNeeded()
    #expect(await spin { !tab.controller.isLoading && tab.controller.blocksView.model != nil })
    controller.window?.contentView?.layoutSubtreeIfNeeded()
    let view = tab.controller.blocksView
    #expect(tab.controller.bottomBar.changeLabel.stringValue == "Change 473 of 944")
    #expect(view.scrollY(of: .a) > 0)
    #expect(view.scrollY(of: .a) == view.scrollY(of: .b))
    #expect(view.scrollA.contentView.bounds.minX == 0 && view.scrollB.contentView.bounds.minX == 0)
    #expect(view.visibleAlignmentError() == 0)

    // The probe is measured in the document window the tab lives in.
    let probe = try #require(tab.controller.selectionProbe(472))
    let window = try #require(controller.window)
    #expect(probe.point[1] > 0 && probe.point[1] < window.frame.height)
    let gutter = view.gutterA
    let inWindow = gutter.convert(NSPoint(x: 4, y: 0), to: nil)
    #expect(gutter.window === window)
    #expect(probe.point[0] == Double(inWindow.x))
}

// MARK: settings apart from the owner's

@Test func testingRunsOfTheAppUseTheirOwnDefaults() {
    let testing = [IPCEnvironment.testingVariable: "1"]
    #expect(AppDefaults.store(environment: testing, isApp: true) !== UserDefaults.standard)
    #expect(AppDefaults.store(environment: [:], isApp: true) === UserDefaults.standard)
    // Unit tests keep their own process's defaults.
    #expect(AppDefaults.store(environment: testing, isApp: false) === UserDefaults.standard)
}

/// Collects every document window the app code registers, for tests that
/// detach tabs. Installed once and never reset: tests run concurrently,
/// so replacing and clearing the shared hook per test lost windows of
/// another test (or handed it the wrong one).
@MainActor
enum RegisteredWindows {
    private static var all: [DocumentWindowController] = []
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        DocumentWindowController.register = { all.append($0) }
    }

    static func find(_ predicate: (DocumentWindowController) -> Bool) -> DocumentWindowController? {
        all.last(where: predicate)
    }

    static func contains(_ controller: DocumentWindowController) -> Bool {
        all.contains { $0 === controller }
    }
}
