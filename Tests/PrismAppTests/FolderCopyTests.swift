// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import Darwin
import FolderCore
import Foundation
import PrismTestSupport
import Testing
@testable import PrismApp

// All copies run inside temporary directories, and every scope gets a
// `DirectoryTrash` in that directory: the user's Trash is never used.

/// A scratch copy of the folder fixtures with fixed times (git keeps none).
private func makeFixture() throws -> TemporaryDirectory {
    let directory = try TemporaryDirectory(prefix: "prism-app-copy")
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

@MainActor
private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A scope over the fixture, watched (so copies show up in its rows), with
/// replaced items going to `<fixture>/trash`.
@MainActor
private struct Harness {
    let fixture: TemporaryDirectory
    let session: FolderSession
    let scope: FolderScopeController

    var left: String { fixture.url.appending(path: "left").path(percentEncoded: false) }
    var right: String { fixture.url.appending(path: "right").path(percentEncoded: false) }
    var trash: String { fixture.url.appending(path: "trash").path(percentEncoded: false) }

    init(level: String = "") async throws {
        _ = NSApplication.shared
        fixture = try makeFixture()
        session = FolderSession(left: fixture.url.appending(path: "left"), right: fixture.url.appending(path: "right"))
        scope = FolderScopeController(session: session, relativePath: level)
        scope.trash = DirectoryTrash(directory: fixture.url.appending(path: "trash").path(percentEncoded: false))
        session.start()
        let scope = self.scope
        _ = await spin { scope.level?.isComplete == true }
    }

    func close() {
        scope.detach()
        session.stop()
        fixture.remove()
    }

    func row(_ name: String) -> FolderRow? { scope.level?.rows.first { $0.name == name } }

    func gutterButton(_ name: String) -> StageButton? {
        guard let index = scope.displayed.firstIndex(where: { $0.name == name }) else { return nil }
        let cell = scope.view.gutter.view(atColumn: 0, row: index, makeIfNecessary: true) as? GutterCell
        return cell?.stageButton
    }

    func copyAndWait() async -> CopyOutcome? {
        var outcome: CopyOutcome?
        scope.onCopyFinished = { outcome = $0 }
        scope.beginCopy()
        _ = await spin(until: { outcome != nil }, timeout: 30)
        return outcome
    }
}

@MainActor
@Suite(.serialized) struct FolderCopyTests {
    @Test func stagingMarksTheRowTheGutterAndTheFooter() async throws {
        let harness = try await Harness()
        defer { harness.close() }
        let scope = harness.scope
        #expect(scope.view.bottomBar.copyStatus.stringValue == FolderBottomBar.idleStatus)
        #expect(!scope.view.bottomBar.copyButton.isEnabled)
        scope.select(name: "docs")
        scope.copyToRight(nil)
        #expect(scope.staging.ordered.map(\.relativePath) == ["docs"])
        #expect(scope.view.bottomBar.copyStatus.stringValue == "1 file to copy")
        #expect(scope.view.bottomBar.copyButton.isEnabled)
        #expect(harness.gutterButton("docs")?.direction == .toRight)
        #expect(harness.gutterButton("docs")?.accessibilityValue() as? String == "Copies to the right")
        let index = try #require(scope.displayed.firstIndex { $0.name == "docs" })
        let rowView = scope.view.tableA.rowView(atRow: index, makeIfNecessary: true) as? FolderRowView
        #expect(rowView?.staged == true)
        // Copy to Left does not apply to a left-only row.
        scope.copyToLeft(nil)
        #expect(scope.staging.count == 1 && harness.gutterButton("docs")?.direction == .toRight)
        // Unchanged rows have no gutter button.
        #expect(harness.gutterButton("README.md")?.isHidden == true)
        #expect(scope.describe()["staged"] as? [String] == ["docs to-right"])
    }

    @Test func undoRemovesTheChevronAndRedoBringsItBack() async throws {
        let harness = try await Harness()
        defer { harness.close() }
        let scope = harness.scope
        scope.stagingUndo.groupsByEvent = false
        scope.select(name: "docs")
        scope.stagingUndo.beginUndoGrouping()
        scope.copyToRight(nil)
        scope.stagingUndo.endUndoGrouping()
        #expect(harness.gutterButton("docs")?.direction == .toRight)
        #expect(scope.stagingUndo.undoActionName == "Copy to Right")
        scope.stagingUndo.undo()
        #expect(scope.staging.isEmpty)
        #expect(harness.gutterButton("docs")?.direction == nil)
        #expect(scope.view.bottomBar.copyStatus.stringValue == FolderBottomBar.idleStatus)
        scope.stagingUndo.redo()
        #expect(harness.gutterButton("docs")?.direction == .toRight)
    }

    @Test func theGutterButtonCyclesThroughTheAllowedDirections() async throws {
        let harness = try await Harness()
        defer { harness.close() }
        let button = try #require(harness.gutterButton("src"))
        #expect(button.allowed == [.toRight, .toLeft] && !button.isHidden)
        #expect(button.accessibilityPerformPress())
        #expect(harness.gutterButton("src")?.direction == .toRight)
        #expect(harness.gutterButton("src")?.accessibilityPerformPress() == true)
        #expect(harness.gutterButton("src")?.direction == .toLeft)
        #expect(harness.scope.staging.ordered.first?.replaces == true)
        #expect(harness.gutterButton("src")?.accessibilityPerformPress() == true)
        #expect(harness.gutterButton("src")?.direction == nil && harness.scope.staging.isEmpty)
        // Reset Selection clears everything when the selection has nothing.
        harness.scope.select(name: "docs")
        harness.scope.copyToRight(nil)
        harness.scope.select(name: "README.md")
        harness.scope.resetSelection(nil)
        #expect(harness.scope.staging.isEmpty)
    }

    @Test func copyingDocsToTheRightMakesTheRowEqual() async throws {
        let harness = try await Harness()
        defer { harness.close() }
        let scope = harness.scope
        scope.select(name: "docs")
        scope.copyToRight(nil)
        let outcome = try #require(await harness.copyAndWait())
        #expect(outcome.copied == ["docs"] && outcome.finished)
        #expect(FileManager.default.contents(atPath: harness.right + "/docs/guide.md")
                == FileManager.default.contents(atPath: harness.left + "/docs/guide.md"))
        #expect(scope.staging.isEmpty && !scope.isCopying)
        #expect(scope.view.bottomBar.copyButton.title == "Copy")
        // FSEvents brings the new state into the rows.
        #expect(await spin { harness.row("docs")?.status == .unchanged })
        #expect(scope.level?.counts == FolderCounts(changed: 1, unchanged: 2, unmatched: 3))
        #expect(scope.view.bottomBar.filterButtons.map(\.title) == ["1 Changed", "2 Unchanged", "3 Unmatched"])
        #expect(!scope.stagingUndo.canUndo)
    }

    @Test func replacingHelperOnTheLeftTrashesTheOldFile() async throws {
        let harness = try await Harness(level: "src/util")
        defer { harness.close() }
        let old = try #require(FileManager.default.contents(atPath: harness.left + "/src/util/helper.swift"))
        harness.scope.select(name: "helper.swift")
        harness.scope.copyToLeft(nil)
        #expect(harness.scope.staging.ordered.first?.replaces == true)
        let outcome = try #require(await harness.copyAndWait())
        #expect(outcome.copied == ["src/util/helper.swift"])
        #expect(FileManager.default.contents(atPath: harness.trash + "/helper.swift") == old)
        #expect(FileManager.default.contents(atPath: harness.left + "/src/util/helper.swift")
                == FileManager.default.contents(atPath: harness.right + "/src/util/helper.swift"))
        #expect(await spin { harness.row("helper.swift")?.status == .unchanged })
    }

    @Test func aReadOnlyDestinationIsReportedAndSkipContinues() async throws {
        let util = try await Harness(level: "src/util")
        defer {
            _ = chmod(util.right + "/src/util", 0o755)
            util.close()
        }
        // A second item in a writable folder: created next to helper.swift
        // on the left only.
        try Data("new".utf8).write(to: URL(filePath: util.left + "/src/util/aaa.txt"))
        #expect(await spin { util.row("aaa.txt") != nil })
        util.scope.select(name: "helper.swift")
        util.scope.copyToRight(nil)
        #expect(chmod(util.right + "/src/util", 0o555) == 0)
        var failures: [CopyFailure] = []
        util.scope.errorResolver = { failures.append($0); return .skip }
        let blocked = try #require(await util.copyAndWait())
        #expect(failures.map(\.relativePath) == ["src/util/helper.swift"] && failures.first?.code == EACCES)
        #expect(failures.first?.reason.contains("Permission denied") == true)
        #expect(blocked.skipped == ["src/util/helper.swift"] && blocked.finished)
        #expect(util.scope.staging.count == 1, "a skipped item stays staged")
    }

    @Test func skipGoesOnWithTheNextItem() async throws {
        let harness = try await Harness()
        defer {
            _ = chmod(harness.left + "/docs/guide.md", 0o644)
            harness.close()
        }
        for name in ["docs", "LICENSE"] {
            harness.scope.select(name: name)
            harness.scope.copyToRight(nil)
        }
        #expect(chmod(harness.left + "/docs/guide.md", 0o000) == 0)
        harness.scope.allowClone = false
        var failures: [String] = []
        harness.scope.errorResolver = { failures.append($0.relativePath); return .skip }
        let outcome = try #require(await harness.copyAndWait())
        #expect(failures == ["docs"])
        #expect(outcome.skipped == ["docs"] && outcome.copied == ["LICENSE"])
        #expect(FileManager.default.fileExists(atPath: harness.right + "/LICENSE"))
        #expect(!FileManager.default.fileExists(atPath: harness.right + "/docs"))
        #expect(harness.scope.staging.ordered.map(\.name) == ["docs"])
    }

    @Test func cancellingStopsAndLeavesNoPartialCopy() async throws {
        let harness = try await Harness()
        defer { harness.close() }
        let big = harness.left + "/big.bin"
        #expect(FileManager.default.createFile(atPath: big, contents: nil))
        let handle = try FileHandle(forWritingTo: URL(filePath: big))
        for _ in 0..<32 { try handle.write(contentsOf: Data(repeating: 7, count: 1 << 20)) }
        try handle.close()
        #expect(await spin { harness.row("big.bin") != nil })
        harness.scope.allowClone = false
        harness.scope.select(name: "big.bin")
        harness.scope.copyToRight(nil)
        var outcome: CopyOutcome?
        harness.scope.onCopyFinished = { outcome = $0 }
        harness.scope.beginCopy()
        #expect(harness.scope.isCopying)
        harness.scope.startCopyingFiles(nil)   // the same command cancels
        #expect(harness.scope.runner?.isCancelling == true || outcome != nil)
        #expect(await spin { outcome != nil })
        #expect(outcome?.cancelled == true || outcome?.copied == ["big.bin"])
        if outcome?.cancelled == true {
            #expect(!FileManager.default.fileExists(atPath: harness.right + "/big.bin"))
            #expect(harness.scope.staging.count == 1)
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: harness.right)) ?? []
        #expect(!names.contains { $0.hasPrefix(".prism-copy-") })
    }

    @Test func undoAndRedoAreOffWhileCopying() async throws {
        _ = NSApplication.shared
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let left = fixture.url.appending(path: "left").path(percentEncoded: false)
        let handle = try FileHandle(forWritingTo: {
            FileManager.default.createFile(atPath: left + "/big.bin", contents: nil)
            return URL(filePath: left + "/big.bin")
        }())
        for _ in 0..<48 { try handle.write(contentsOf: Data(repeating: 1, count: 1 << 20)) }
        try handle.close()
        let controller = FolderWindowController(left: fixture.url.appending(path: "left"),
                                                right: fixture.url.appending(path: "right"))
        defer { controller.close() }
        let scope = try #require((controller.tabs.first as? FolderTab)?.scope)
        scope.trash = DirectoryTrash(directory: fixture.url.appending(path: "trash").path(percentEncoded: false))
        scope.allowClone = false
        #expect(await spin { scope.level?.isComplete == true && scope.level?.rows.contains { $0.name == "big.bin" } == true })
        scope.stagingUndo.groupsByEvent = false
        scope.select(name: "big.bin")
        scope.stagingUndo.beginUndoGrouping()
        scope.copyToRight(nil)
        scope.stagingUndo.endUndoGrouping()
        let window = try #require(controller.window)
        #expect(controller.windowWillReturnUndoManager(window) === scope.stagingUndo)
        var outcome: CopyOutcome?
        scope.onCopyFinished = { outcome = $0 }
        scope.beginCopy()
        #expect(scope.isCopying)
        #expect(controller.windowWillReturnUndoManager(window) == nil)
        // Even a direct undo cannot change the staging mid-copy.
        if scope.stagingUndo.canUndo { scope.stagingUndo.undo() }
        #expect(scope.staging.count == 1 || outcome != nil)
        #expect(await spin(until: { outcome != nil }, timeout: 30))
        #expect(outcome?.copied == ["big.bin"])
    }

    @Test func cancellingTheAppBundleWarningAsksAgain() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(prefix: "prism-app-bundle-warn")
        defer { directory.remove() }
        for side in ["A.app", "B.app"] {
            try FileManager.default.createDirectory(at: directory.url.appending(path: side + "/Contents"),
                                                    withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: directory.url.appending(path: "A.app/Contents/Info.plist"))
        let session = FolderSession(left: directory.url.appending(path: "A.app"), right: directory.url.appending(path: "B.app"))
        defer { session.stop() }
        let scope = FolderScopeController(session: session, relativePath: "Contents")
        defer { scope.detach() }
        session.start(watch: false)
        #expect(await spin { scope.level?.isComplete == true })
        var asked = 0, answer = false
        scope.appBundleConfirmer = { reply in
            asked += 1
            reply(answer)
        }
        let settings = FolderSettings()
        let previous = settings.warnOnAppBundles
        settings.warnOnAppBundles = true
        defer { settings.warnOnAppBundles = previous }
        scope.select(name: "Info.plist")
        scope.copyToRight(nil)
        #expect(asked == 1 && scope.staging.isEmpty && !scope.appBundleWarningShown)
        answer = true
        scope.copyToRight(nil)
        #expect(asked == 2 && scope.staging.count == 1 && scope.appBundleWarningShown)
        scope.resetSelection(nil)
        scope.copyToRight(nil)
        #expect(asked == 2 && scope.staging.count == 1, "asked once per tab after Continue")
    }

    @Test func listingALevelCleansStaleTemporaries() async throws {
        let harness = try await Harness()
        defer { harness.close() }
        try Data("partial".utf8).write(to: URL(filePath: harness.right + "/.prism-copy-ABCD1234-LICENSE"))
        let box = HandledBox()
        harness.scope.cleanStaleTemporaries(minimumAge: 0) { box.set($0) }
        #expect(await spin { box.value == [".prism-copy-ABCD1234-LICENSE"] })
        #expect(!FileManager.default.fileExists(atPath: harness.right + "/.prism-copy-ABCD1234-LICENSE"))
    }

    @Test func anOverlappingCopyIsRefused() async throws {
        let harness = try await Harness()
        defer { harness.close() }
        let lease = try CopyLock.shared.acquire([harness.session.rightPath]).get()
        defer { lease.release() }
        harness.scope.select(name: "docs")
        harness.scope.copyToRight(nil)
        harness.scope.beginCopy()
        #expect(!harness.scope.isCopying)
        #expect(!FileManager.default.fileExists(atPath: harness.right + "/docs"))
    }

    @Test func summaryPhrasesAndMenu() throws {
        let entry = FolderEntry(name: "docs", kind: .directory, size: 10, modificationTimeNs: 0, isReadable: true,
                                key: 1, isDeep: true)
        let new = StagedCopy(row: FolderRow(left: entry, right: nil, status: .leftOnly), levelPath: "", direction: .toRight)
        let replace = StagedCopy(row: FolderRow(left: entry, right: entry, status: .changed), levelPath: "", direction: .toLeft)
        #expect(CopySummarySheet.phrase(new) == "copies to B")
        #expect(CopySummarySheet.phrase(replace) == "replaces the one in A")
        let sheet = CopySummarySheet(items: [new, replace], leftName: "left", rightName: "right")
        #expect(sheet.numberOfRows(in: sheet.table) == 2)
        #expect(sheet.copyButton.keyEquivalent == "\r" && sheet.cancelButton.keyEquivalent == "\u{1b}")

        let menu = MainMenuBuilder.make(target: NSObject())
        let merge = try #require(menu.item(withTitle: MainMenuBuilder.mergeMenuTitle)?.submenu)
        // In a folder window the text-only items are hidden.
        MergeMenuContext.update(merge) { FolderScopeController.instancesRespond(to: $0) }
        let items = merge.items.filter { !$0.isSeparatorItem && !$0.isHidden }
        #expect(items.map(\.title) == ["Copy to Right", "Copy to Left", "Reset Selection", "Start Copying Files"])
        #expect(items[0].keyEquivalent == MainMenuBuilder.rightArrow && items[0].keyEquivalentModifierMask == .command)
        #expect(items[1].keyEquivalent == MainMenuBuilder.leftArrow)
        #expect(items[2].keyEquivalent == "\u{8}" && items[2].keyEquivalentModifierMask == [.command, .option])
        #expect(items[3].keyEquivalent == "\r" && items[3].keyEquivalentModifierMask == .command)
        // The shared items reach the folder scope through the responder chain.
        #expect(items.allSatisfy { FolderScopeController.instancesRespond(to: $0.action!) })
    }

    /// With no key window (Prism in the background), menu commands, their
    /// validation and Undo/Redo reach the frontmost folder window's
    /// selected tab: the folder scope, or a text tab's comparison.
    @Test func backgroundMenuCommandsReachTheFrontmostFolderWindow() async throws {
        _ = NSApplication.shared
        let fixture = try makeFixture()
        let controller = FolderWindowController(left: fixture.url.appending(path: "left"),
                                                right: fixture.url.appending(path: "right"))
        defer { controller.close() }
        let window = try #require(controller.window)
        #expect(window.isKeyWindow == false)
        #expect(PrismApplication.frontmostDocumentWindow(in: [window], isVisible: { _ in true }) === window)
        let scope = try #require((controller.tabs.first as? FolderTab)?.scope)
        #expect(await spin { scope.level?.isComplete == true && scope.level?.rows.contains { $0.name == "docs" } == true })
        scope.select(name: "docs")

        func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }
        let copyRight = item(#selector(FolderScopeController.copyToRight(_:)))
        let start = item(#selector(FolderScopeController.startCopyingFiles(_:)))
        let target = PrismApplication.target(forAction: copyRight.action!, in: window)
        #expect(target as AnyObject? === scope)
        #expect((target as? NSMenuItemValidation)?.validateMenuItem(copyRight) == true)
        #expect(PrismApplication.target(forAction: start.action!, in: window) as AnyObject? === scope)
        #expect(!scope.validateMenuItem(start))
        #expect(PrismApplication.target(forAction: #selector(ComparisonWindowController.keepBothLeftFirst(_:)), in: window) == nil)

        let merge = try #require(MainMenuBuilder.make(target: NSObject()).item(withTitle: MainMenuBuilder.mergeMenuTitle)?.submenu)
        MergeMenuContext.update(merge) { PrismApplication.target(forAction: $0, in: window) != nil }
        #expect(merge.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map(\.title)
            == ["Copy to Right", "Copy to Left", "Reset Selection", "Start Copying Files"])

        // Staging through the routed target; Undo uses the staging history.
        _ = NSApp.sendAction(copyRight.action!, to: target, from: copyRight)
        #expect(scope.staging.count == 1)
        #expect(scope.validateMenuItem(start))
        #expect(PrismApplication.target(forAction: Selector(("undo:")), in: window) as AnyObject? === window)
        #expect(window.undoManager === scope.stagingUndo)
        #expect(window.undoManager?.canUndo == true)

        // Routed Undo, then Redo, as the Edit menu sends them.
        let undoItem = item(Selector(("undo:"))), redoItem = item(Selector(("redo:")))
        func press(_ menuItem: NSMenuItem) throws -> Bool {
            let target = try #require(PrismApplication.target(forAction: menuItem.action!, in: window))
            guard (target as? NSMenuItemValidation)?.validateMenuItem(menuItem) == true else { return false }
            return NSApp.sendAction(menuItem.action!, to: target, from: menuItem)
        }
        #expect(undoItem.title.isEmpty)
        #expect(try press(undoItem))
        #expect(scope.staging.isEmpty)
        #expect(window.undoManager?.canRedo == true)
        #expect((window as NSMenuItemValidation).validateMenuItem(redoItem))
        #expect(redoItem.title == "Redo Copy to Right")
        #expect(try press(redoItem))
        #expect(scope.staging.count == 1)

        // A background refresh follows the selection: Copy to Left is off
        // for a left-only row and on for a changed one, without opening
        // the menu.
        let mergeMenu = NSMenu(title: "Merge")
        let copyLeft = mergeMenu.addItem(withTitle: "Copy to Left", action: #selector(FolderScopeController.copyToLeft(_:)),
                                     keyEquivalent: "")
        copyLeft.target = scope
        scope.select(name: "LICENSE")
        PrismApplication.refresh(mergeMenu)
        #expect(!copyLeft.isEnabled)
        scope.select(name: "src")
        PrismApplication.refresh(mergeMenu)
        #expect(copyLeft.isEnabled)

        // A selected text tab takes the text commands and its own undo.
        let tab = controller.addTextTab(a: Corpus.fixture("text/a.swift"), b: Corpus.fixture("text/b.swift"),
                                        key: "text:a", title: "a | b", at: 1)
        #expect(PrismApplication.target(forAction: #selector(ComparisonWindowController.keepBothLeftFirst(_:)),
                                        in: window) as AnyObject? === tab.controller)
        #expect(PrismApplication.target(forAction: copyRight.action!, in: window) as AnyObject? === tab.controller)
        #expect(window.undoManager === tab.controller.session.undoManager)
    }

    @Test func settingsDefaultsAndTrashChoice() throws {
        let suite = "prism-copy-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FolderSettings(defaults: defaults)
        #expect(settings.showCopySummary && settings.warnOnAppBundles)
        settings.showCopySummary = false
        #expect(!settings.showCopySummary)
        #expect(FolderTrash.current(environment: ["PRISM_TRASH_DIR": "/tmp/x"]) is DirectoryTrash)
        #expect(FolderTrash.current(environment: [:]) is SystemTrash)
    }

    @Test func appBundlesAreDetected() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(prefix: "prism-app-bundle")
        defer { directory.remove() }
        for side in ["A.app", "B.app"] {
            try FileManager.default.createDirectory(at: directory.url.appending(path: side + "/Contents"),
                                                    withIntermediateDirectories: true)
        }
        let session = FolderSession(left: directory.url.appending(path: "A.app"), right: directory.url.appending(path: "B.app"))
        defer { session.stop() }
        let scope = FolderScopeController(session: session, relativePath: "Contents")
        defer { scope.detach() }
        #expect(scope.isInsideAppBundle)
        let fixture = try await Harness()
        defer { fixture.close() }
        #expect(!fixture.scope.isInsideAppBundle)
    }
}

private final class HandledBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func set(_ value: [String]) { lock.withLock { stored = value } }
    var value: [String] { lock.withLock { stored } }
}

/// Folder comparisons confirm "changed" files by their contents unless the
/// user turned it off: equal files that only differ in date show unchanged.
@Test func compareContentsIsOnByDefault() throws {
    let suite = "prism.test.contents.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = FolderSettings(defaults: defaults)
    #expect(settings.compareContents)
    #expect(settings.options.compareContents)
    settings.compareContents = false
    #expect(!settings.compareContents)
}
