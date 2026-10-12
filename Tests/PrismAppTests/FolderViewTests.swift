// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import Darwin
import FolderCore
import Foundation
import PrismTestSupport
import Testing
@testable import PrismApp

/// A scratch copy of the folder fixtures with fixed times (git keeps none).
private func makeFixture() throws -> TemporaryDirectory {
    let directory = try TemporaryDirectory(prefix: "prism-app-folders")
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

/// Yields the main actor (so main-queue deliveries run) until `condition`
/// holds or the timeout passes.
@MainActor
private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
@Suite struct FolderViewTests {
    @Test func titlesDisambiguateSameNamesWithTheRoots() {
        #expect(FolderWindowController.title(relativePath: "", leftName: "left", rightName: "right",
                                             roots: ("left", "right")) == "left | right")
        #expect(FolderWindowController.title(relativePath: "src", leftName: "src", rightName: "src",
                                             roots: ("left", "right")) == "src (left) | src (right)")
        #expect(FolderWindowController.title(relativePath: "a/b", leftName: "x", rightName: "y",
                                             roots: ("l", "r")) == "x | y")
    }

    @Test func bottomBarShowsCountsAndMapsCheckboxesToTheFilter() {
        let bar = FolderBottomBar()
        bar.setCounts(FolderCounts(changed: 1, unchanged: 1, unmatched: 4))
        #expect(bar.filterButtons.map(\.title) == ["1 Changed", "1 Unchanged", "4 Unmatched"])
        #expect(bar.filter == .all)
        bar.unmatchedButton.state = .off
        #expect(bar.filter == [.changed, .unchanged])
        bar.filter = []
        #expect(!bar.filter.shows(.changed) && !bar.filter.shows(.leftOnly) && !bar.filter.shows(.unchanged))
    }

    @Test func statusColoursExistForEveryDifference() {
        #expect(FolderColors.background(.unchanged) == nil)
        for status in [RowStatus.changed, .leftOnly, .rightOnly] {
            #expect(FolderColors.background(status) != nil)
        }
    }

    @Test func scopeShowsAlignedRowsAndFiltersThem() async throws {
        _ = NSApplication.shared
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let session = FolderSession(left: fixture.url.appending(path: "left"), right: fixture.url.appending(path: "right"))
        defer { session.stop() }
        let scope = FolderScopeController(session: session, relativePath: "")
        defer { scope.detach() }
        session.start(watch: false)
        #expect(await spin { scope.level?.isComplete == true })
        #expect(scope.displayed.count == 6)
        #expect(scope.level?.counts == FolderCounts(changed: 1, unchanged: 1, unmatched: 4))
        // Alignment: one row per item, a blank side where an item is missing.
        #expect(scope.view.tableA.numberOfRows == 6 && scope.view.tableB.numberOfRows == 6)
        #expect(scope.displayed.map { $0.left?.name ?? "-" } == ["-", "-", "docs", "LICENSE", "README.md", "src"])
        #expect(scope.displayed.map { $0.right?.name ?? "-" } == ["assets", "CHANGELOG.md", "-", "-", "README.md", "src"])

        scope.setFilter(.changed)
        #expect(scope.displayed.map(\.name) == ["src"])
        #expect(scope.view.bottomBar.filterButtons.map(\.title) == ["1 Changed", "1 Unchanged", "4 Unmatched"])
        scope.setFilter(.unmatched)
        #expect(scope.displayed.count == 4)
        scope.setFilter(.all)
        #expect(scope.displayed.count == 6)

        // Selection is shared by both tables.
        scope.select(name: "src")
        #expect(scope.view.tableB.selectedRow == 5)
        var opened: [String] = []
        scope.onOpen = { _, row, _ in opened.append(row.name) }
        scope.openSelection(nil)
        #expect(opened == ["src"])
        scope.selectPreviousChange(nil)
        #expect(scope.selectedRows.first?.name == "LICENSE")
    }

    @Test func windowOpensDrillDownTabsAndTextTabs() async throws {
        _ = NSApplication.shared
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let controller = FolderWindowController(left: fixture.url.appending(path: "left"),
                                                right: fixture.url.appending(path: "right"))
        defer { controller.close() }
        let root = try #require(controller.tabs.first as? FolderTab)
        #expect(await spin { root.scope.level?.isComplete == true })
        let src = try #require(root.scope.displayed.first { $0.name == "src" })
        controller.open(src, from: root.scope, newWindow: false)
        #expect(controller.tabs.map(\.title) == ["left | right", "src (left) | src (right)"])
        #expect(controller.selectedIndex == 1)
        // Opening the same pair again selects the existing tab.
        controller.selectTab(0)
        controller.open(src, from: root.scope, newWindow: false)
        #expect(controller.tabs.count == 2 && controller.selectedIndex == 1)

        let srcTab = try #require(controller.tabs[1] as? FolderTab)
        #expect(await spin { srcTab.scope.level?.isComplete == true })
        #expect(srcTab.scope.level?.counts == FolderCounts(changed: 2, unchanged: 0, unmatched: 0))
        let main = try #require(srcTab.scope.displayed.first { $0.name == "main.swift" })
        controller.open(main, from: srcTab.scope, newWindow: false)
        let text = try #require(controller.tabs.last as? TextTab)
        #expect(text.title == "main.swift (left) | main.swift (right)")
        #expect(await spin { text.controller.blocksView.model != nil })
        #expect(text.controller.blocksView.model?.changeCount == 8)

        // A one-sided file cannot be opened; a one-sided folder can.
        let license = try #require(root.scope.displayed.first { $0.name == "LICENSE" })
        controller.open(license, from: root.scope, newWindow: false)
        #expect(controller.tabs.count == 3)
        let docs = try #require(root.scope.displayed.first { $0.name == "docs" })
        controller.open(docs, from: root.scope, newWindow: false)
        #expect(controller.tabs.count == 4)
        controller.closeTab(controller.selectedIndex)
        #expect(controller.tabs.count == 3)
    }
}
