// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import DiffCore
import PrismTestSupport
import Testing
@testable import PrismApp

// Regression tests for the M6 review: text tabs of folder windows, quitting
// with the editor open, external changes, selection and caret after a
// re-diff, line endings, metadata on save, resolved inserts and Keep Both,
// and the editor's life cycle. No window is ever shown.

private func folder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "prism-m6r-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func pair(_ name: String, _ a: String, _ b: String) throws -> (URL, URL) {
    let base = try folder(name)
    let urlA = base.appending(path: "a.txt"), urlB = base.appending(path: "b.txt")
    try Data(a.utf8).write(to: urlA)
    try Data(b.utf8).write(to: urlB)
    return (urlA, urlB)
}

@MainActor
private func open(_ a: URL, _ b: URL) throws -> EditSession {
    let session = EditSession(a: a, b: b, temporaryRoots: [])
    let source = ImportedTextSource()
    session.load(a: try source.load(a), b: try source.load(b), urls: (a, b))
    return session
}

@MainActor
private func model(_ session: EditSession) throws -> ComparisonModel {
    let texts = try #require(session.texts)
    return try ComparisonModel.build(a: texts.a, b: texts.b, whitespace: .exact, resolved: session.resolvedRegions)
}

private func string(_ bytes: [UInt8]?) -> String { String(decoding: bytes ?? [], as: UTF8.self) }
private func contents(_ url: URL) throws -> String { string([UInt8](try Data(contentsOf: url))) }

@MainActor
private func settle(_ controller: ComparisonWindowController) async throws {
    let deadline = ContinuousClock.now + .seconds(60)
    try await Task.sleep(for: .milliseconds(1))
    while controller.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
}

@MainActor
private func loadedController(_ a: URL, _ b: URL) async throws -> ComparisonWindowController {
    _ = NSApplication.shared
    let controller = ComparisonWindowController(a: a, b: b)
    controller.session.temporaryRoots = []
    controller.reload()
    try await settle(controller)
    return controller
}

/// Opens the editor on `line` of `side` with the caret at `offset`.
@MainActor
private func beginEditing(_ controller: ComparisonWindowController, _ side: DiffSide, line: Int,
                          offset: Int = 0) throws -> Bool {
    let geometry = try #require(controller.blocksView.geometry(for: side))
    let row = try #require(geometry.rows.row(ofLine: line, side: side))
    let caret = TextPosition(row: row, offset: offset)
    return controller.blocksView.onBeginEditing?(side, TextSelection(pane: side, anchor: caret, head: caret), nil) ?? false
}

// MARK: 1. text tabs of folder windows

@MainActor
@Test func folderTextTabsGuardTheirEdits() async throws {
    _ = NSApplication.shared
    let left = try folder("tab-left"), right = try folder("tab-right")
    try Data("1\n2\n3\n".utf8).write(to: left.appending(path: "f.txt"))
    try Data("1\nX\n3\n".utf8).write(to: right.appending(path: "f.txt"))
    let host = FolderWindowController(left: left, right: right)
    defer { host.window?.close() }
    let tab = host.addTextTab(a: left.appending(path: "f.txt"), b: right.appending(path: "f.txt"),
                              key: "text:f.txt", title: "f.txt", at: 1)
    let controller = tab.controller
    controller.session.temporaryRoots = []
    try await settle(controller)
    #expect(controller.hostWindow === host.window)
    #expect(controller.presentingWindow === host.window)
    #expect(host.textTabs.count == 1 && !tab.hasUnsavedChanges)

    controller.blocksView.selectChange(0, scroll: false)
    controller.copyToRight(nil)
    try await settle(controller)
    #expect(controller.session.isDirty)
    // The folder window shows the edited dot and undoes the tab's edits.
    #expect(host.window?.isDocumentEdited == true)
    let window = try #require(host.window)
    #expect(host.windowWillReturnUndoManager(window) === controller.session.undoManager)
    #expect(tab.hasUnsavedChanges)

    // Closing the tab or the window asks first; with no window on screen
    // to ask on, nothing closes and nothing is lost.
    let tabCount = host.tabs.count
    host.requestCloseTab(1)
    #expect(host.tabs.count == tabCount)
    #expect(controller.lastRefusal?.title.contains("unsaved") == true)
    #expect(!host.windowShouldClose(window))
    #expect(host.tabs.count == tabCount)
    #expect(try contents(right.appending(path: "f.txt")) == "1\nX\n3\n")

    // Undo through the folder window's manager clears the dot.
    controller.session.undoManager.undo()
    try await settle(controller)
    #expect(host.window?.isDocumentEdited == false)
    host.requestCloseTab(1)
    #expect(host.tabs.count == tabCount - 1)
    #expect(host.windowShouldClose(window))
}

// MARK: 2. quitting with the editor open

@MainActor
@Test func textInTheEditorCountsAsUnsaved() async throws {
    let (a, b) = try pair("quit", "1\n2\n3\n", "1\nX\n3\n")
    let controller = try await loadedController(a, b)
    #expect(try beginEditing(controller, .b, line: 1))
    controller.editor.textView?.insertText("typed ", replacementRange: NSRange(location: 0, length: 0))
    #expect(!controller.session.isDirty)
    // The quit and close checks commit the editor first.
    #expect(controller.hasUnsavedChanges)
    #expect(!controller.editor.isEditing)
    #expect(string(controller.session.texts?.b.bytes) == "1\ntyped X\n3\n")
    let app = AppDelegate()
    #expect(app.textComparisons.isEmpty)
}

// MARK: 3. external changes

@MainActor
@Test func savingDoesNotOverwriteExternalChanges() async throws {
    let (a, b) = try pair("ext", "1\n2\n3\n", "1\nX\n3\n")
    let session = try open(a, b)
    try Data("1\nX\n3\nIMPORTANT external line\n".utf8).write(to: b)
    try session.merge(.copyToRight, change: 0, in: try model(session))
    #expect {
        try session.save(.b)
    } throws: { ($0 as? EditSession.Refusal)?.kind == .changedOnDisk }
    #expect(try contents(b) == "1\nX\n3\nIMPORTANT external line\n")
    try session.save(.b, overwritingExternalChanges: true)
    #expect(try contents(b) == "1\n2\n3\n")
    // Saved again: the new stamp is the reference.
    try session.replaceLines(0 ..< 1, of: .b, with: "one\n", selecting: nil)
    try session.save(.b)
    #expect(try contents(b) == "one\n2\n3\n")

    // The window does not overwrite either (no sheet to ask on: refused).
    let (c, d) = try pair("ext-window", "1\n2\n3\n", "1\nX\n3\n")
    let controller = try await loadedController(c, d)
    controller.copyToRight(nil)
    try await settle(controller)
    try Data("changed elsewhere\n".utf8).write(to: d)
    controller.saveComparison(nil)
    #expect(try contents(d) == "changed elsewhere\n")
    #expect(controller.session.isDirty)
    #expect(controller.lastRefusal?.title.contains("another application") == true)
}

// MARK: 4. selection after a merge

@MainActor
@Test func theMergedChangeStaysSelected() async throws {
    // A copy that makes the diff align differently: the numbering moves,
    // the selection follows the merged lines.
    let (a, b) = try pair("focus", "c\n\na\nb\nb\n\nb\nc\nb\n}\n{\n", "b\na\n\nb\na\nb\n")
    let controller = try await loadedController(a, b)
    let before = try #require(controller.blocksView.model)
    #expect(before.changeCount == 5)
    controller.blocksView.selectChange(3, scroll: false)
    controller.copyToLeft(nil)
    try await settle(controller)
    let after = try #require(controller.blocksView.model)
    let selected = try #require(controller.blocksView.selectedChange)
    let marker = try #require(controller.session.markers.first)
    let block = after.layout.blocks[after.layout.changes[selected]]
    #expect(block.a == marker.a && block.b == marker.b)
    #expect(after.layout.resolved.contains(after.layout.changes[selected]))
    #expect(controller.session.canReset(change: selected, in: after))
}

@MainActor
@Test func mergesKeepAFindableResolvedChange() throws {
    var generator = SeededGenerator(seed: 0x6d06)
    var trials = 0, missing = 0, resetBad = 0, undoBad = 0
    let alphabet = ["a", "b", "c", "a", "b", "{", "}", ""]
    for round in 0 ..< 300 {
        func text() -> String {
            (0 ..< Int.random(in: 3 ... 12, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }
                .joined(separator: "\n") + "\n"
        }
        let (a, b) = try pair("fuzz\(round)", text(), text())
        let session = try open(a, b)
        let start = try model(session)
        guard start.changeCount > 0 else { continue }
        trials += 1
        let index = Int.random(in: 0 ..< start.changeCount, using: &generator)
        let choice = PrismApp.MergeChoice.allCases.randomElement(using: &generator)!
        let original = (session.texts!.a.bytes, session.texts!.b.bytes)
        try session.merge(choice, change: index, in: start)
        let merged = try model(session)
        let marker = try #require(session.markers.first)
        guard let found = merged.change(covering: marker.a, marker.b),
              session.canReset(change: found, in: merged) else {
            missing += 1
            continue
        }
        try session.reset(change: found, in: merged)
        if (session.texts!.a.bytes, session.texts!.b.bytes) != original { resetBad += 1 }
        session.undoManager.undo()
        session.undoManager.undo()
        if (session.texts!.a.bytes, session.texts!.b.bytes) != original || session.isDirty { undoBad += 1 }
    }
    #expect(trials > 200)
    // A merge can make the diff line up the text around the merged lines
    // differently; rarely no change is left that shares its lines (an
    // emptied region inside a longer difference, or merged text that now
    // matches other lines). Never a wrong reset.
    #expect(missing * 20 <= trials, "missing \(missing) of \(trials)")
    #expect(resetBad == 0 && undoBad == 0, "reset \(resetBad) undo \(undoBad)")
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: 5. caret after a re-diff

@MainActor
@Test func theCaretStaysOnTheEditedLine() async throws {
    let lines = (1 ... 40).map { "line\($0)" }
    let (a, b) = try pair("caret", lines.joined(separator: "\n") + "\n",
                          lines.map { $0 == "line30" ? "CHANGED" : $0 }.joined(separator: "\n") + "\n")
    let controller = try await loadedController(a, b)
    #expect(try beginEditing(controller, .a, line: 29, offset: 2))
    controller.editor.textView?.insertText("X", replacementRange: NSRange(location: 2, length: 0))
    controller.editor.commit()
    try await settle(controller)
    let caret = try #require(controller.blocksView.caretLine())
    #expect(caret.pane == .a && caret.side == .a && caret.line == 29 && caret.offset == 3)

    // A merge keeps the caret on its line too.
    controller.blocksView.placeCaret(pane: .b, side: .b, line: 10, offset: 1)
    controller.copyToRight(nil)
    try await settle(controller)
    let kept = try #require(controller.blocksView.caretLine())
    #expect(kept.pane == .b && kept.line == 10 && kept.offset == 1)
}

// MARK: 6 and 9. line endings

@MainActor
@Test func editsKeepEachLinesTerminator() throws {
    let (a, b) = try pair("mixed", "h\r\nl1\r\nl2\nl3\r\nt\r\n", "h\r\nm1\r\nm2\nm3\r\nt\r\n")
    let session = try open(a, b)
    let shown = session.editableText(1 ..< 4, of: .b)
    try session.replaceLines(1 ..< 4, of: .b, with: shown.replacingOccurrences(of: "m1", with: "M1"), selecting: 0)
    #expect(string(session.texts?.b.bytes) == "h\r\nM1\r\nm2\nm3\r\nt\r\n")
    // An added line takes the file's main terminator.
    try session.replaceLines(1 ..< 2, of: .b, with: "M1\nnew\n", selecting: 0)
    #expect(string(session.texts?.b.bytes) == "h\r\nM1\r\nnew\r\nm2\nm3\r\nt\r\n")

    try Data("h\nc1\rc2\nt\n".utf8).write(to: b)
    let lone = try open(a, b)
    let text = lone.editableText(1 ..< 3, of: .b)
    try lone.replaceLines(1 ..< 3, of: .b, with: text.replacingOccurrences(of: "c2", with: "C2"), selecting: 0)
    #expect(string(lone.texts?.b.bytes) == "h\nc1\rC2\nt\n")
}

@MainActor
@Test func pastedLineBreaksAreNotDoubled() throws {
    let (a, b) = try pair("paste", "h\r\nx\r\nt\r\n", "h\r\nm1\r\nt\r\n")
    let session = try open(a, b)
    try session.replaceLines(1 ..< 2, of: .b, with: "p1\r\np2\rp3\u{2028}p4\n", selecting: 0)
    #expect(string(session.texts?.b.bytes) == "h\r\np1\r\np2\r\np3\r\np4\r\nt\r\n")
    #expect(LineText.lineCount(session.texts!.b.bytes) == 6)
    #expect(LineText.normalizingBreaks("a\r\nb\rc\u{2029}d") == "a\nb\nc\nd")
}

// MARK: 7. saving keeps the file

@MainActor
@Test func savingKeepsHardLinksAndNamesTheFile() throws {
    let (a, b) = try pair("meta", "x\n", "y\n")
    let hard = b.deletingLastPathComponent().appending(path: "hard.txt")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: b.path)
    _ = b.withUnsafeFileSystemRepresentation { setxattr($0!, "user.prism", "v", 1, 0, 0) }
    try FileManager.default.linkItem(at: b, to: hard)
    let inode = try FileManager.default.attributesOfItem(atPath: b.path)[.systemFileNumber] as? Int
    let session = try open(a, b)
    try session.merge(.copyToRight, change: 0, in: try model(session))
    try session.save(.b)
    let attributes = try FileManager.default.attributesOfItem(atPath: b.path)
    #expect(attributes[.systemFileNumber] as? Int == inode)
    #expect(try contents(hard) == "x\n")
    #expect(attributes[.posixPermissions] as? Int == 0o755)
    #expect(b.withUnsafeFileSystemRepresentation { getxattr($0!, "user.prism", nil, 0, 0, 0) } == 1)

    // Without a second link the file is replaced, keeping its attributes.
    try FileManager.default.removeItem(at: hard)
    try session.replaceLines(0 ..< 1, of: .b, with: "z\n", selecting: nil)
    try session.save(.b)
    #expect(try contents(b) == "z\n")
    #expect(try FileManager.default.attributesOfItem(atPath: b.path)[.posixPermissions] as? Int == 0o755)
    #expect(b.withUnsafeFileSystemRepresentation { getxattr($0!, "user.prism", nil, 0, 0, 0) } == 1)
    // No temporary file is left behind.
    let names = try FileManager.default.contentsOfDirectory(atPath: b.deletingLastPathComponent().path)
    #expect(names.sorted() == ["a.txt", "b.txt"])
}

@MainActor
@Test func saveErrorsNameTheRealFile() throws {
    let (a, b) = try pair("readonly", "x\n", "y\n")
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: b.path)
    let session = try open(a, b)
    try session.merge(.copyToRight, change: 0, in: try model(session))
    var message = ""
    do { try session.save(.b) } catch { message = error.description }
    #expect(message.contains("b.txt") && !message.contains(".prism-"))
    #expect(try contents(b) == "y\n")

    // A writable file in a read-only folder is written in place.
    let (c, d) = try pair("rodir", "x\n", "y\n")
    let parent = d.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
    let other = try open(c, d)
    try other.merge(.copyToRight, change: 0, in: try model(other))
    try other.save(.b)
    #expect(try contents(d) == "x\n")
}

// MARK: 8. resolved inserts, deletions and Keep Both

@MainActor
@Test func copiedInsertsAndKeepBothStayResolved() throws {
    let (a, b) = try pair("del", "1\n2\nX\n3\n4\nY\n5\n", "1\n2\n3\n4\nZ\n5\n")
    let session = try open(a, b)
    let start = try model(session)
    #expect(start.changeCount == 2)
    try session.merge(.copyToLeft, change: 0, in: start) // removes X from A
    var merged = try model(session)
    #expect(merged.changeCount == 2)
    #expect(session.markers.count == 1 && session.canReset(change: 0, in: merged))
    let empty = merged.layout.blocks[merged.layout.changes[0]]
    #expect(empty.a.isEmpty && empty.b.isEmpty && merged.layout.resolved.contains(merged.layout.changes[0]))
    try session.reset(change: 0, in: merged)
    #expect(string(session.texts?.a.bytes) == "1\n2\nX\n3\n4\nY\n5\n")

    // Keep Both: the change is shown resolved (one uncoloured block).
    let (c, d) = try pair("both", "x\na\nb\ny\n", "x\nb\na\nb\ny\n")
    let both = try open(c, d)
    try both.merge(.keepBothLeftFirst, change: 0, in: try model(both))
    merged = try model(both)
    #expect(merged.changeCount == 1)
    let block = merged.layout.blocks[merged.layout.changes[0]]
    #expect(block.kind == .equal && merged.layout.resolved.contains(merged.layout.changes[0]))
    #expect(both.canReset(change: 0, in: merged))
    // Unified shows both of its sides.
    let rows = PaneRows(kind: .unified, layout: merged.layout, lineCounts: (merged.a.lineCount, merged.b.lineCount))
    #expect(rows.rows(ofBlock: merged.layout.changes[0]).count == block.a.count + block.b.count)
}

// MARK: 10 and 11. the editor's life cycle

@MainActor
@Test func layoutChangesCommitTheEditor() async throws {
    let (a, b) = try pair("mode", "1\n2\n3\n", "1\nX\n3\n")
    let controller = try await loadedController(a, b)
    let saved = UserDefaults.standard.string(forKey: TextSettings.Key.viewMode)
    defer { UserDefaults.standard.set(saved, forKey: TextSettings.Key.viewMode) }
    for change in [{ controller.setMode(.unified) }, { controller.toggleWrapLines(nil) },
                   { controller.increaseTextSize(nil) }] {
        #expect(try beginEditing(controller, .a, line: 0))
        controller.editor.textView?.insertText("e", replacementRange: NSRange(location: 0, length: 0))
        change()
        #expect(!controller.editor.isEditing && controller.editor.textView == nil)
        try await settle(controller)
        controller.setMode(.blocks)
    }
    #expect(string(controller.session.texts?.a.bytes) == "eee1\n2\n3\n")
    controller.toggleWrapLines(nil)
}

@MainActor
@Test func beginningAgainAfterACommitWaitsForTheRediff() async throws {
    let (a, b) = try pair("rebegin", "1\n2\n3\n", "1\nX\n3\n")
    let controller = try await loadedController(a, b)
    #expect(try beginEditing(controller, .a, line: 0))
    controller.editor.textView?.insertText("NEW\n", replacementRange: NSRange(location: 0, length: 0))
    let geometry = try #require(controller.blocksView.geometry(for: .a))
    let row = try #require(geometry.rows.row(ofLine: 2, side: .a))
    let caret = TextPosition(row: row, offset: 0)
    // The pending edit is handed back; the stale rows are not used.
    #expect(!controller.editor.begin(pane: .a, selection: TextSelection(pane: .a, anchor: caret, head: caret), event: nil))
    #expect(!controller.editor.isEditing)
    try await settle(controller)
    #expect(string(controller.session.texts?.a.bytes) == "NEW\n1\n2\n3\n")
    #expect(try beginEditing(controller, .a, line: 3))
    #expect(controller.editor.region?.lines == 3 ..< 4)
    controller.editor.commit()
}
