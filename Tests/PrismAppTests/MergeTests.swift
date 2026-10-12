// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import DiffCore
import PrismTestSupport
import Testing
@testable import PrismApp

// Tests of the M7 three-way merge window: the session (choices, edits,
// undo, saving, the resolved state), the layouts, the window's close
// questions and the outcome it reports, the menus, and offscreen renders.
// No window is ever shown.

// MARK: helpers

/// A folder for files the tests write; under PRISM_M07_OUT when set (the
/// acceptance script compares them).
private func mergeFolder(_ name: String) throws -> URL {
    let base: URL
    if let out = ProcessInfo.processInfo.environment["PRISM_M07_OUT"], !out.isEmpty {
        base = URL(filePath: out, directoryHint: .isDirectory)
    } else {
        base = FileManager.default.temporaryDirectory.appending(path: "prism-m7-\(UUID().uuidString)")
    }
    let folder = base.appending(path: name, directoryHint: .isDirectory)
    try? FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// The files of corpus merge case `name` copied to a folder, with an output
/// file holding conflict markers (as git leaves it).
private func mergeCase(_ name: String, folder: String? = nil, base: Bool = true) throws -> MergeFiles {
    let target = try mergeFolder(folder ?? name)
    let source = Corpus.directory.appending(path: "merge/\(name)", directoryHint: .isDirectory)
    for file in ["a.txt", "b.txt", "base.txt"] {
        try FileManager.default.copyItem(at: source.appending(path: file), to: target.appending(path: file))
    }
    let output = target.appending(path: "merged.txt")
    try Data("<<<<<<< conflict markers left by git\n".utf8).write(to: output)
    return MergeFiles(a: target.appending(path: "a.txt"), b: target.appending(path: "b.txt"),
                      base: base ? target.appending(path: "base.txt") : nil, output: output)
}

@MainActor
private func loadedSession(_ files: MergeFiles) throws -> MergeSession {
    let session = MergeSession(files: files)
    let computed = try MergeSession.compute(files: files, source: ImportedTextSource())
    session.load(texts: computed.texts, result: computed.result)
    return session
}

@MainActor
private func loadedController(_ files: MergeFiles, mode: ViewMode = .unified) async throws -> MergeWindowController {
    _ = NSApplication.shared
    let controller = MergeWindowController(files: files)
    controller.setMode(mode)
    controller.load()
    let deadline = ContinuousClock.now + .seconds(60)
    try await Task.sleep(for: .milliseconds(1))
    while controller.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    return controller
}

private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

// MARK: session

@MainActor
@Test func chooseLeftThenSaveResolvesTheMerge() throws {
    let files = try mergeCase("notes", folder: "notes-left")
    let session = try loadedSession(files)
    #expect(session.conflicts.count == 1)
    #expect(session.unresolvedCount == 1)
    #expect(!session.isResolved && session.isDirty)
    let conflict = try #require(session.conflicts.first)
    #expect(session.output(ofRegion: conflict).placeholder)

    session.choose(.a, region: conflict)
    #expect(session.unresolvedCount == 0)
    #expect(!session.isResolved, "not saved yet")
    try session.save()
    #expect(session.isResolved && !session.isDirty)
    #expect(try text(files.output) == "line1\nline2 main\nline3\n")
}

@MainActor
@Test func everyChoiceAndResetGivesItsText() throws {
    let session = try loadedSession(try mergeCase("notes", folder: "notes-choices"))
    let conflict = try #require(session.conflicts.first)
    let expected: [(DiffCore.MergeChoice, String)] = [
        (.a, "line1\nline2 main\nline3\n"),
        (.b, "line1\nline2 feature\nline3\n"),
        (.aThenB, "line1\nline2 main\nline2 feature\nline3\n"),
        (.bThenA, "line1\nline2 feature\nline2 main\nline3\n"),
    ]
    for (choice, text) in expected {
        session.choose(choice, region: conflict)
        #expect(String(decoding: session.outputBytes, as: UTF8.self) == text)
    }
    session.reset(region: conflict)
    #expect(session.unresolvedCount == 1)
    // Unresolved, the saved text keeps A's lines.
    #expect(String(decoding: session.outputBytes, as: UTF8.self) == "line1\nline2 main\nline3\n")
}

@MainActor
@Test func choicesUndoAndRedo() throws {
    let session = try loadedSession(try mergeCase("notes", folder: "notes-undo"))
    let conflict = try #require(session.conflicts.first)
    session.choose(.b, region: conflict)
    #expect(session.undoManager.undoActionName == "Choose Right")
    session.undoManager.undo()
    #expect(session.unresolvedCount == 1)
    session.undoManager.redo()
    #expect(session.unresolvedCount == 0)
    #expect(String(decoding: session.outputBytes, as: UTF8.self) == "line1\nline2 feature\nline3\n")
}

@MainActor
@Test func typingOverAConflictResolvesIt() throws {
    let files = try mergeCase("notes", folder: "notes-typed")
    let session = try loadedSession(files)
    let conflict = try #require(session.conflicts.first)
    #expect(session.editableText(ofRegion: conflict) == "")
    session.edit(region: conflict, text: "line2 both\nline2 extra")
    #expect(session.unresolvedCount == 0)
    try session.save()
    #expect(try text(files.output) == "line1\nline2 both\nline2 extra\nline3\n")
    session.undoManager.undo()
    #expect(session.unresolvedCount == 1 && session.isDirty)
}

@MainActor
@Test func withoutABaseEveryDifferenceIsAConflict() throws {
    let session = try loadedSession(try mergeCase("disjoint", folder: "disjoint-nobase", base: false))
    #expect(!session.differences.isEmpty)
    #expect(session.conflicts == session.differences)
}

/// The automatic resolution the window starts from equals the corpus
/// golden for every case (the merged text of expected.json).
@MainActor
@Test(arguments: ["a-only", "b-only", "disjoint", "same-edit", "overlap-conflict", "insert-same-point",
                  "delete-vs-edit", "notes", "mixed", "adjacent-change-insert", "append-after-closing-line",
                  "split-by-agreement"])
func automaticResolutionMatchesTheGolden(_ name: String) throws {
    let session = try loadedSession(try mergeCase(name, folder: "auto-\(name)"))
    let golden = Corpus.directory.appending(path: "merge/\(name)/expected.json")
    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: golden)) as? [String: Any])
    let merged = try #require(object["merged"] as? String)
    #expect(String(decoding: session.outputBytes, as: UTF8.self) == merged)
    #expect(session.unresolvedCount == object["unresolved"] as? Int)
}

// MARK: layout

@MainActor
@Test func layoutsPlaceTheConflictAndItsPlaceholder() throws {
    let session = try loadedSession(try mergeCase("notes", folder: "notes-layout"))
    let display = MergeDisplay(session: session)
    #expect(display.unresolvedCount == 1)
    let conflict = try #require(display.regions.firstIndex { $0.kind == .conflict })
    #expect(display.regions[conflict].placeholder && display.regions[conflict].output == [""])

    let blocks = MergeLayout(display, mode: .blocks)
    #expect(blocks.columns.count == 3)
    #expect(Set(blocks.columns.map(\.count)).count == 1, "Blocks pads every column to the same height")
    #expect(blocks.columns[1][1].content == .placeholder(number: 2))
    #expect(blocks.columns[0][1].content == .line(.a, 1, number: 2, numberB: nil))
    #expect(blocks.columns[2][1].content == .line(.b, 1, number: 2, numberB: nil))

    let unified = MergeLayout(display, mode: .unified)
    #expect(unified.columns.count == 2)
    // line1, then A's line 2, B's line 2, then line3.
    #expect(unified.columns[0].map(\.content) == [
        .line(.a, 0, number: 1, numberB: 1), .line(.a, 1, number: 2, numberB: nil),
        .line(.b, 1, number: nil, numberB: 2), .line(.a, 2, number: 3, numberB: 3),
    ])
    #expect(unified.columns[1][1].content == .placeholder(number: 2))
    // The result column is not padded: line3 follows the placeholder.
    #expect(unified.columns[1][2].content == .line(.output, 2, number: 3, numberB: nil))

    let fluid = MergeLayout(display, mode: .fluid)
    #expect(fluid.columns.map(\.count) == [3, 3, 3])
    #expect(fluid.spans[1][conflict] == 1 ..< 2)
}

// MARK: window

@MainActor
@Test func windowChooseLeftSaveAndCloseReportsResolved() async throws {
    let files = try mergeCase("notes", folder: "window-left")
    let controller = try await loadedController(files)
    var outcome: Bool?
    controller.onFinish = { outcome = $0 }
    #expect(controller.window?.title == "Prism")
    #expect(controller.window?.accessibilityLabel() == "merged.txt")
    #expect(controller.header.statusText == "(1) Unresolved Conflicts")
    #expect(controller.conflictLabel == "Conflict 1 of 1 \u{26A0}")
    #expect(controller.closeQuestion == .unresolvedConflicts)

    controller.copyToRight(nil)                 // Choose Left
    #expect(controller.header.statusText == "Resolved Document")
    #expect(controller.conflictLabel == "Conflict 1 of 1 \u{2713}")
    #expect(controller.closeQuestion == .unsavedChanges)
    #expect(controller.saveComparison(nil))
    #expect(controller.closeQuestion == nil)
    controller.window?.close()
    #expect(outcome == true)
    #expect(try text(files.output) == "line1\nline2 main\nline3\n")
}

@MainActor
@Test func windowClosedWithoutResolvingReportsUnresolved() async throws {
    let files = try mergeCase("notes", folder: "window-unresolved")
    let before = try text(files.output)
    let controller = try await loadedController(files)
    var outcome: Bool?
    controller.onFinish = { outcome = $0 }
    // Review Conflicts keeps the window and selects the conflict.
    controller.answer(.unresolvedConflicts, .alertFirstButtonReturn)
    #expect(outcome == nil)
    #expect(controller.selectedRegion == controller.session.conflicts.first)
    // Don't Resolve closes it unresolved; the output is left alone.
    controller.answer(.unresolvedConflicts, .alertSecondButtonReturn)
    #expect(outcome == false)
    #expect(try text(files.output) == before)
}

@MainActor
@Test func savedButChangedAgainIsNotResolved() async throws {
    let files = try mergeCase("notes", folder: "window-changed")
    let controller = try await loadedController(files)
    var outcome: Bool?
    controller.onFinish = { outcome = $0 }
    controller.copyToLeft(nil)                  // Choose Right
    #expect(controller.saveComparison(nil))
    controller.keepBothLeftFirst(nil)
    #expect(controller.closeQuestion == .unsavedChanges)
    controller.answer(.unsavedChanges, .alertSecondButtonReturn)   // Don't Save
    #expect(outcome == false)
    #expect(try text(files.output) == "line1\nline2 feature\nline3\n")
}

@MainActor
@Test func conflictNavigationAndMenuValidation() async throws {
    let files = try mergeCase("mixed", folder: "window-nav")
    let controller = try await loadedController(files, mode: .blocks)
    let differences = controller.session.differences
    #expect(differences.count == 4)
    #expect(controller.selectedRegion == controller.session.conflicts.first)
    controller.selectNextChange(nil)
    #expect(controller.selectedRegion == differences.first, "wraps around to the first change")
    controller.selectNextConflict(nil)
    #expect(controller.selectedRegion == controller.session.conflicts.first)
    func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }
    #expect(controller.validateMenuItem(item(#selector(MergeWindowController.copyToRight(_:)))))
    #expect(!controller.validateMenuItem(item(#selector(MergeWindowController.resetSelection(_:)))))
    controller.copyToRight(nil)
    #expect(controller.validateMenuItem(item(#selector(MergeWindowController.resetSelection(_:)))))
    controller.resetSelection(nil)
    #expect(controller.session.unresolvedCount == 1)
    controller.window?.close()
}

@MainActor
@Test func typingInTheResultColumnResolves() async throws {
    let files = try mergeCase("notes", folder: "window-typed")
    let controller = try await loadedController(files, mode: .blocks)
    let conflict = try #require(controller.session.conflicts.first)
    controller.beginEditing(region: conflict)
    let editor = try #require(controller.editor)
    editor.string = "line2 merged by hand"
    controller.commitEditing()
    #expect(controller.session.unresolvedCount == 0)
    #expect(controller.saveComparison(nil))
    #expect(try text(files.output) == "line1\nline2 merged by hand\nline3\n")
    controller.window?.close()
}

// MARK: menus

@MainActor
@Test func mergeMenuIsRenamedForThreeWayMerges() throws {
    let menu = MainMenuBuilder.make(target: NSObject())
    let merge = try #require(menu.item(withTitle: MainMenuBuilder.mergeMenuTitle)?.submenu)
    func visible() -> [String] { merge.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "-" : $0.title } }
    MergeMenuContext.update(merge) { MergeWindowController.instancesRespond(to: $0) }
    #expect(visible() == ["Choose Left", "Choose Right", "Reset Selection", "-",
                          "Choose Both (Left First)", "Choose Both (Right First)"])
    let keys = merge.items.filter { !$0.isHidden && !$0.isSeparatorItem }
        .map { "\($0.keyEquivalentModifierMask.intersection([.command, .option, .shift]).rawValue):\($0.keyEquivalent)" }
    let right = MainMenuBuilder.rightArrow, left = MainMenuBuilder.leftArrow
    let command = NSEvent.ModifierFlags.command.rawValue
    let optionCommand = NSEvent.ModifierFlags([.command, .option]).rawValue
    #expect(keys == ["\(command):\(right)", "\(command):\(left)", "\(optionCommand):\(MainMenuBuilder.backspace)",
                     "\(optionCommand):\(right)", "\(optionCommand):\(left)"])
    // Back to a two-way comparison: the usual names.
    MergeMenuContext.update(merge) { ComparisonWindowController.instancesRespond(to: $0) }
    #expect(visible().first == "Copy to Right")

    let view = try #require(menu.item(withTitle: MainMenuBuilder.viewMenuTitle)?.submenu)
    let previous = try #require(view.item(withTitle: "Previous Conflict"))
    let next = try #require(view.item(withTitle: "Next Conflict"))
    #expect(previous.keyEquivalent == MainMenuBuilder.upArrow && next.keyEquivalent == MainMenuBuilder.downArrow)
    #expect(previous.keyEquivalentModifierMask == [.command, .option])
    #expect(next.keyEquivalentModifierMask == [.command, .option])
}

// MARK: renders

@MainActor
@Test func rendersMergeLayoutsOffscreen() async throws {
    guard let shots = ProcessInfo.processInfo.environment["PRISM_M07_SHOTS"], !shots.isEmpty else { return }
    let output = URL(filePath: shots, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let controller = try await loadedController(try mergeCase("notes", folder: "shots"))
    func shoot(_ name: String) throws {
        let view = try #require(controller.window?.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: output.appending(path: "\(name).png"))
    }
    controller.setMode(.unified)
    try shoot("m07-unified")
    controller.setMode(.blocks)
    try shoot("m07-blocks")
    controller.setMode(.fluid)
    try shoot("m07-fluid")
    controller.copyToRight(nil)
    try shoot("m07-fluid-resolved-left")
    controller.setMode(.unified)
    let mixed = try await loadedController(try mergeCase("mixed", folder: "shots-mixed"), mode: .fluid)
    let view = try #require(mixed.window?.contentView)
    view.layoutSubtreeIfNeeded()
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    try #require(rep.representation(using: .png, properties: [:])).write(to: output.appending(path: "m07-mixed-fluid.png"))
    controller.window?.close()
    mixed.window?.close()
}
