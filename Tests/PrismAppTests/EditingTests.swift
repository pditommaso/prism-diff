// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import DiffCore
import PrismTestSupport
import Testing
@testable import PrismApp

// Tests of the M6 editing layer: merge choices, free editing, undo and
// redo, saving in the original encoding, the guards, and the window's
// actions and menus. Everything runs without showing a window.

// MARK: helpers

/// A folder for files the tests write. When PRISM_M06_OUT is set (the
/// acceptance script does), files are left there for byte comparisons.
private func workFolder(_ name: String) throws -> URL {
    let base: URL
    if let out = ProcessInfo.processInfo.environment["PRISM_M06_OUT"], !out.isEmpty {
        base = URL(filePath: out, directoryHint: .isDirectory)
    } else {
        base = FileManager.default.temporaryDirectory.appending(path: "prism-m6-\(UUID().uuidString)")
    }
    let folder = base.appending(path: name, directoryHint: .isDirectory)
    try? FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func copyFixture(_ name: String, to folder: URL, as target: String? = nil) throws -> URL {
    let destination = folder.appending(path: target ?? name)
    try FileManager.default.copyItem(at: Corpus.fixture("text/\(name)"), to: destination)
    return destination
}

/// A session over two files, read the way the app reads them. Temporary
/// folders are not guarded unless asked.
@MainActor
private func session(_ a: URL, _ b: URL, guardingTemporary: Bool = false) throws -> EditSession {
    let session = EditSession(a: a, b: b, temporaryRoots: guardingTemporary ? EditSession.defaultTemporaryRoots() : [])
    let source = ImportedTextSource()
    session.load(a: try source.load(a), b: try source.load(b), urls: (a, b))
    return session
}

@MainActor
private func model(_ session: EditSession, whitespace: WhitespaceMode = .exact) throws -> ComparisonModel {
    let texts = try #require(session.texts)
    return try ComparisonModel.build(a: texts.a, b: texts.b, whitespace: whitespace, resolved: session.resolvedRegions)
}

private func lineText(_ model: ComparisonModel, _ side: DiffSide, _ line: Int) -> String {
    model.side(side).text(ofLine: line)
}

private func fileBytes(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }

@MainActor
private func settle(_ controller: ComparisonWindowController) async throws {
    let deadline = ContinuousClock.now + .seconds(60)
    try await Task.sleep(for: .milliseconds(1))
    while controller.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
}

// MARK: line edits

@Test func lineEditsKeepLineBoundaries() {
    let text = Array("one\ntwo\nthree".utf8)
    // Replace a middle line with text that does not end a line: a
    // terminator is added because a line follows.
    var result = LineEdit(side: .a, lines: 1 ..< 2, text: Array("TWO".utf8)).apply(to: text)
    #expect(String(decoding: result.bytes, as: UTF8.self) == "one\nTWO\nthree")
    #expect(result.lines == 1 ..< 2)
    // Insert after an unterminated last line: it starts on a new line.
    result = LineEdit(side: .a, lines: 3 ..< 3, text: Array("four\n".utf8)).apply(to: text)
    #expect(String(decoding: result.bytes, as: UTF8.self) == "one\ntwo\nthree\nfour\n")
    #expect(result.lines == 3 ..< 4)
    // Delete lines.
    result = LineEdit(side: .a, lines: 0 ..< 2, text: []).apply(to: text)
    #expect(String(decoding: result.bytes, as: UTF8.self) == "three")
    #expect(result.lines == 0 ..< 0)
    // CRLF files get CRLF.
    let crlf = Array("a\r\nb\r\n".utf8)
    result = LineEdit(side: .b, lines: 0 ..< 1, text: Array("x".utf8)).apply(to: crlf)
    #expect(result.bytes == Array("x\r\nb\r\n".utf8))
    #expect(LineText.terminator(of: crlf) == [0x0D, 0x0A])
    #expect(LineText.converting("p\nq\n", terminator: [0x0D, 0x0A]) == Array("p\r\nq\r\n".utf8))
    #expect(LineText.lineCount(Array("a\rb\r\nc".utf8)) == 3)
}

@Test func mergeChoicesCombineTheOriginalLines() {
    let a = Array("a1\na2\n".utf8), b = Array("b1\n".utf8)
    #expect(MergeChoice.copyToRight.result(a: a, b: b) == (a, a))
    #expect(MergeChoice.copyToLeft.result(a: a, b: b) == (b, b))
    #expect(MergeChoice.keepBothLeftFirst.result(a: a, b: b) == (a, a + b))
    #expect(MergeChoice.keepBothRightFirst.result(a: a, b: b) == (b + a, b))
    // A part without a final newline is ended before the next one.
    let last = Array("end".utf8)
    #expect(MergeChoice.keepBothLeftFirst.result(a: last, b: b).b == Array("end\nb1\n".utf8))
    #expect(MergeChoice.copyToRight.destination == .b && MergeChoice.keepBothRightFirst.destination == .a)
}

@Test func markersMoveWithEditsAndDropWhenTouched() {
    let marker = MergeMarker(a: 10 ..< 12, b: 20 ..< 22, originalA: [], originalB: [], choice: .copyToRight)
    // Above it: moves.
    #expect(marker.shifted(side: .a, replacing: 2 ..< 3, with: 4)?.a == 13 ..< 15)
    #expect(marker.shifted(side: .a, replacing: 10 ..< 10, with: 1)?.a == 11 ..< 13)
    // Below it, or on the other side's numbering: stays.
    #expect(marker.shifted(side: .a, replacing: 12 ..< 14, with: 0)?.a == 10 ..< 12)
    #expect(marker.shifted(side: .b, replacing: 30 ..< 31, with: 3)?.b == 20 ..< 22)
    #expect(marker.shifted(side: .a, replacing: 12 ..< 12, with: 2)?.a == 10 ..< 12)
    // Inside it: dropped.
    #expect(marker.shifted(side: .a, replacing: 11 ..< 13, with: 1) == nil)
    #expect(marker.shifted(side: .b, replacing: 21 ..< 21, with: 1) == nil)
}

@Test func resolvedRegionsSplitUnchangedBlocks() {
    let blocks = [DiffBlock(kind: .equal, a: 0 ..< 10, b: 0 ..< 10),
                  DiffBlock(kind: .change, a: 10 ..< 11, b: 10 ..< 11),
                  DiffBlock(kind: .equal, a: 11 ..< 20, b: 11 ..< 20)]
    let (split, resolved) = ComparisonModel.splitting(blocks, at: [(3 ..< 5, 3 ..< 5), (15 ..< 20, 15 ..< 20),
                                                                   (10 ..< 11, 10 ..< 11)])
    #expect(split.map(\.a) == [0 ..< 3, 3 ..< 5, 5 ..< 10, 10 ..< 11, 11 ..< 15, 15 ..< 20])
    #expect(resolved == [1, 3, 5])
    let layout = BlocksLayout(blocks: split, resolved: resolved, lineCounts: (20, 20), showsTrailer: (true, true))
    #expect(layout.changes == [1, 3, 5])
}

// MARK: merging (screen 05)

@MainActor
@Test func copyToRightOnChangeTwoUndoesAndRedoes() throws {
    let folder = try workFolder("copy-right")
    let a = try copyFixture("a.swift", to: folder), b = try copyFixture("b.swift", to: folder)
    let session = try session(a, b)
    var selections: [EditSession.Focus] = []
    session.onChange = { selections.append($0) }
    let before = try model(session)
    #expect(before.changeCount == 8)
    #expect(lineText(before, .a, 2) == "/// Computes greeting for a user.")
    #expect(lineText(before, .b, 3) != lineText(before, .a, 2))
    let original = try #require(session.texts?.b.bytes)

    try session.merge(.copyToRight, change: 1, in: before)
    let after = try model(session)
    // B's line 4 is now A's line 3, and the change is still listed (as
    // resolved), so the numbering does not move.
    #expect(lineText(after, .b, 3) == lineText(after, .a, 2))
    #expect(after.changeCount == 8)
    #expect(after.layout.resolved.contains(after.layout.changes[1]))
    #expect(session.isDirty(.b) && !session.isDirty(.a))
    #expect(session.undoManager.undoActionName == "Copy to Right")
    // The rebuilt comparison selects the merged lines.
    let merged = EditSession.Focus.region(a: 2 ..< 3, b: 3 ..< 4)
    #expect(selections == [merged])
    #expect(after.change(covering: 2 ..< 3, 3 ..< 4) == 1)

    session.undoManager.undo()
    #expect(session.texts?.b.bytes == original)
    #expect(!session.isDirty)
    #expect(try model(session).changeCount == 8)
    #expect(session.undoManager.canRedo)

    session.undoManager.redo()
    let redone = try model(session)
    #expect(lineText(redone, .b, 3) == lineText(redone, .a, 2))
    #expect(session.isDirty(.b))
    #expect(selections == [merged, merged, merged])
}

@MainActor
@Test func applyingEveryChangeLeftToRightMakesBIdenticalToA() throws {
    let folder = try workFolder("all-right")
    let a = try copyFixture("a.swift", to: folder), b = try copyFixture("b.swift", to: folder)
    let session = try session(a, b)
    var steps = 0
    while steps < 50 {
        let current = try model(session)
        guard let index = current.layout.changes.firstIndex(where: { !current.layout.resolved.contains($0) })
        else { break }
        try session.merge(.copyToRight, change: index, in: current)
        steps += 1
    }
    #expect(steps == 8)
    #expect(session.texts?.b.bytes == session.texts?.a.bytes)
    try session.save(.b)
    #expect(try fileBytes(b) == fileBytes(a))
    #expect(try fileBytes(b) == fileBytes(Corpus.fixture("text/a.swift")))
    #expect(!session.isDirty)
    // A is untouched on disk.
    #expect(try fileBytes(a) == fileBytes(Corpus.fixture("text/a.swift")))
}

@MainActor
@Test func applyingEveryChangeRightToLeftMakesAIdenticalToB() throws {
    let folder = try workFolder("all-left")
    let a = try copyFixture("a.swift", to: folder), b = try copyFixture("b.swift", to: folder)
    let session = try session(a, b)
    for _ in 0 ..< 50 {
        let current = try model(session)
        guard let index = current.layout.changes.firstIndex(where: { !current.layout.resolved.contains($0) })
        else { break }
        try session.merge(.copyToLeft, change: index, in: current)
    }
    #expect(session.texts?.a.bytes == session.texts?.b.bytes)
}

@MainActor
@Test func keepBothResetAndAnotherChoice() throws {
    let folder = try workFolder("keep-both")
    let a = folder.appending(path: "a.txt"), b = folder.appending(path: "b.txt")
    try Data("top\nleft\nbottom\n".utf8).write(to: a)
    try Data("top\nright\nbottom\n".utf8).write(to: b)
    let session = try session(a, b)
    let start = try model(session)
    #expect(start.changeCount == 1)

    try session.merge(.keepBothLeftFirst, change: 0, in: start)
    #expect(session.texts.map { String(decoding: $0.b.bytes, as: UTF8.self) } == "top\nleft\nright\nbottom\n")
    #expect(session.texts.map { String(decoding: $0.a.bytes, as: UTF8.self) } == "top\nleft\nbottom\n")
    var current = try model(session)
    // What is left is B's extra line, still the selected change.
    #expect(current.changeCount == 1)
    #expect(session.canReset(change: 0, in: current))

    // Another choice starts again from the original lines.
    try session.merge(.keepBothRightFirst, change: 0, in: current)
    #expect(session.texts.map { String(decoding: $0.a.bytes, as: UTF8.self) } == "top\nright\nleft\nbottom\n")
    #expect(session.texts.map { String(decoding: $0.b.bytes, as: UTF8.self) } == "top\nright\nbottom\n")
    current = try model(session)
    try session.merge(.copyToLeft, change: 0, in: current)
    #expect(session.texts?.a.bytes == Array("top\nright\nbottom\n".utf8))
    #expect(session.texts?.b.bytes == Array("top\nright\nbottom\n".utf8))
    current = try model(session)
    #expect(current.changeCount == 1 && current.layout.resolved.count == 1)

    // Reset Selection: both sides as they were, no marker left.
    try session.reset(change: 0, in: current)
    #expect(session.texts?.a.bytes == Array("top\nleft\nbottom\n".utf8))
    #expect(session.texts?.b.bytes == Array("top\nright\nbottom\n".utf8))
    #expect(session.markers.isEmpty && !session.isDirty)
    #expect(session.undoManager.undoActionName == "Reset Selection")
    session.undoManager.undo()
    #expect(session.texts?.a.bytes == Array("top\nright\nbottom\n".utf8))
}

@MainActor
@Test func insertsAndDeletesCopyBothWays() throws {
    let folder = try workFolder("insert-delete")
    let a = folder.appending(path: "a.txt"), b = folder.appending(path: "b.txt")
    try Data("one\nthree\nfour".utf8).write(to: a)
    try Data("one\ntwo\nthree\n".utf8).write(to: b)
    let session = try session(a, b)
    var current = try model(session)
    #expect(current.changeCount == 2)
    // Copy the inserted line to the left.
    try session.merge(.copyToLeft, change: 0, in: current)
    #expect(session.texts?.a.bytes == Array("one\ntwo\nthree\nfour".utf8))
    current = try model(session)
    // Copy the last change (A's unterminated last line) to the right.
    let last = current.changeCount - 1
    try session.merge(.copyToRight, change: last, in: current)
    #expect(session.texts?.b.bytes == session.texts?.a.bytes)
}

// MARK: free editing

@MainActor
@Test func editedLinesKeepUTF16AndCRLFWhenSaved() throws {
    let folder = try workFolder("utf16-crlf")
    let a = folder.appending(path: "a.txt"), b = folder.appending(path: "b.txt")
    func utf16(_ text: String) -> [UInt8] { [0xFF, 0xFE] + Array(text.data(using: .utf16LittleEndian)!) }
    let original = utf16("first line\r\nsecond line\r\nthird line \u{00E9}\u{4E2D}\r\n")
    try Data(original).write(to: a)
    try Data(original).write(to: b)
    let session = try session(a, b)
    #expect(session.text(.b)?.format?.encoding == .utf16LittleEndian)
    #expect(session.text(.b)?.format?.hasBOM == true)
    #expect(session.editableText(1 ..< 2, of: .b) == "second line\n")

    try session.replaceLines(1 ..< 2, of: .b, with: "second line, edited\nan added line\n", selecting: nil)
    try session.save(.b)
    let expected = utf16("first line\r\nsecond line, edited\r\nan added line\r\nthird line \u{00E9}\u{4E2D}\r\n")
    #expect(try fileBytes(b) == expected)
    try Data(expected).write(to: folder.appending(path: "expected.txt"))
    // Unchanged text saves byte for byte.
    try session.replaceLines(0 ..< 1, of: .a, with: "first line\n", selecting: nil)
    #expect(!session.isDirty(.a))
}

@MainActor
@Test func freeEditsAreOneUndoStepAndShiftMarkers() throws {
    let folder = try workFolder("free-edit")
    let a = try copyFixture("a.swift", to: folder), b = try copyFixture("b.swift", to: folder)
    let session = try session(a, b)
    var current = try model(session)
    try session.merge(.copyToRight, change: 7, in: current)
    let marker = try #require(session.markers.first)
    // Typing two extra lines near the top of B moves the marker down.
    try session.replaceLines(0 ..< 1, of: .b, with: "import Foundation\n// one\n// two\n", selecting: 0)
    #expect(session.markers.first?.b == marker.b.lowerBound + 2 ..< marker.b.upperBound + 2)
    current = try model(session)
    #expect(lineText(current, .b, 1) == "// one")
    #expect(session.undoManager.undoActionName == "Typing")
    session.undoManager.undo()
    #expect(session.markers.first == marker)
    session.undoManager.undo()
    #expect(!session.isDirty)
}

// MARK: guards

@MainActor
@Test func mergingIntoATemporaryCopyIsRefused() throws {
    // The files live in $TMPDIR, as a version-control snapshot would.
    let folder = FileManager.default.temporaryDirectory.appending(path: "prism-m6-snap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let a = try copyFixture("a.swift", to: folder), b = try copyFixture("b.swift", to: folder)
    let session = try session(a, b, guardingTemporary: true)
    let before = try #require(session.texts)
    let current = try model(session)
    #expect(session.refusal(toChange: .b) != nil)
    #expect(throws: EditSession.Refusal.self) { try session.merge(.copyToRight, change: 1, in: current) }
    #expect(throws: EditSession.Refusal.self) { try session.merge(.copyToLeft, change: 1, in: current) }
    #expect(throws: EditSession.Refusal.self) {
        try session.replaceLines(0 ..< 1, of: .a, with: "x\n", selecting: nil)
    }
    #expect(session.texts?.a == before.a && session.texts?.b == before.b)
    #expect(!session.undoManager.canUndo)
    #expect(try fileBytes(b) == fileBytes(Corpus.fixture("text/b.swift")))
}

@MainActor
@Test func unreadableEncodingsAreReadOnly() throws {
    let folder = try workFolder("lossy")
    let a = folder.appending(path: "a.txt"), b = folder.appending(path: "b.txt")
    try Data("x\n".utf8).write(to: a)
    try Data([0x79, 0xFF, 0x0A]).write(to: b)
    let session = EditSession(a: a, b: b, temporaryRoots: [])
    // Repaired UTF-8: nothing to write it back with.
    session.load(a: UTF8TextSource.decode(Array("x\n".utf8)), b: UTF8TextSource.decode([0x79, 0xFF, 0x0A]),
                 urls: (a, b))
    #expect(session.text(.b)?.format == nil)
    let current = try model(session)
    #expect(throws: EditSession.Refusal.self) { try session.merge(.copyToRight, change: 0, in: current) }
    #expect(throws: EditSession.Refusal.self) { try session.save(.b) }
}

@MainActor
@Test func charactersTheEncodingCannotHoldAreNotSaved() throws {
    let folder = try workFolder("latin1")
    let a = folder.appending(path: "a.txt"), b = folder.appending(path: "b.txt")
    try Data("caf\u{00E9}\n".data(using: .isoLatin1)!).write(to: a)
    try Data("caf\u{00E9}\n".data(using: .isoLatin1)!).write(to: b)
    let session = try session(a, b)
    try session.replaceLines(0 ..< 1, of: .b, with: "\u{4E2D}\n", selecting: nil)
    if session.text(.b)?.format?.encoding != .utf8 {
        #expect(throws: EditSession.Refusal.self) { try session.save(.b) }
        #expect(session.isDirty(.b))
    }
}

// MARK: saving

@MainActor
@Test func savingKeepsTheFileAndFollowsSymbolicLinks() throws {
    let folder = try workFolder("symlink")
    let real = folder.appending(path: "real.txt"), link = folder.appending(path: "link.txt")
    let other = folder.appending(path: "other.txt")
    try Data("old\n".utf8).write(to: real)
    try Data("new\n".utf8).write(to: other)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: real.path)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let session = try session(other, link)
    try session.merge(.copyToRight, change: 0, in: try model(session))
    try session.save(.b)
    #expect(try fileBytes(real) == Array("new\n".utf8))
    let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
    #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
    let permissions = try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int
    #expect(permissions == 0o640)
}

// MARK: re-diff speed

@MainActor
@Test func editingABigFileRediffsAndRepaintsQuickly() throws {
    let folder = try workFolder("big")
    let a = try copyFixture("big_a.txt", to: folder), b = try copyFixture("big_b.txt", to: folder)
    let session = try session(a, b)
    _ = NSApplication.shared
    let view = BlocksDiffView(font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                              theme: BuiltinThemes.multicolorLight)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled],
                          backing: .buffered, defer: true)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    view.show(try model(session))
    view.scroll(toY: view.metrics.y(ofRow: 50_000))
    let line = try #require(view.scrollAnchor().line)
    let old = session.editableText(line ..< line + 1, of: .b)
    var times: [Double] = []
    var parts: [String] = []
    for round in 0 ..< 3 {
        let start = DispatchTime.now().uptimeNanoseconds
        func lap(_ name: String) {
            parts.append("\(name)=\(Int(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6))")
        }
        try session.replaceLines(line ..< line + 1, of: .b, with: "edited \(round) " + old, selecting: nil)
        lap("edit")
        let rebuilt = try model(session)
        lap("diff")
        view.show(rebuilt, keepingPosition: true)
        lap("show")
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        lap("paint")
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        #expect(view.visibleAlignmentError() == 0)
        #expect(view.scrollAnchor().line == line)
    }
    let best = try #require(times.min())
    let report = "edit+rediff+repaint big_b ms: \(times.map { ($0 * 10).rounded() / 10 }) \(parts)"
    print(report)
    try? Data((report + "\n").utf8).write(to: folder.appending(path: "timing.txt"))
    // The budget is judged on an optimised build (`swift test -c release
    // -Xswiftc -enable-testing`, as the M06 acceptance script runs it): a
    // debug build of the diff engine is some 40 times slower. Best of three.
    #if DEBUG
    #expect(best > 0)
    #else
    // PRISM_PERF_SCALE stretches the budget on slower machines (CI).
    let scale = Double(ProcessInfo.processInfo.environment["PRISM_PERF_SCALE"] ?? "") ?? 1
    #expect(best <= 150 * scale, "\(report)")
    #endif
}

// MARK: window

/// Only menu commands are routed to the frontmost document window; other
/// target lookups (AppKit's own, accessibility among them) keep AppKit's.
@MainActor
@Test func onlyMenuCommandsAreRoutedInTheBackground() {
    let menu = MainMenuBuilder.make(target: NSObject())
    let copyRight = #selector(ComparisonWindowController.copyToRight(_:))
    let item = NSMenuItem(title: "", action: copyRight, keyEquivalent: "")
    #expect(PrismApplication.isMenuCommand(copyRight, sender: nil, menu: menu))
    #expect(PrismApplication.isMenuCommand(Selector(("undo:")), sender: nil, menu: menu))
    #expect(PrismApplication.isMenuCommand(Selector(("anything:")), sender: item, menu: nil))
    #expect(!PrismApplication.isMenuCommand(#selector(NSApplication.accessibilityWindows), sender: nil, menu: menu))
    #expect(!PrismApplication.isMenuCommand(copyRight, sender: NSButton(), menu: nil))
}

/// With no key window (Prism in the background), menu commands, their
/// validation and Undo/Redo reach the frontmost text comparison.
@MainActor
@Test func backgroundMenuCommandsReachTheFrontmostTextWindow() async throws {
    _ = NSApplication.shared
    let folder = try workFolder("background")
    let a = try copyFixture("a.swift", to: folder), b = try copyFixture("b.swift", to: folder)
    let controller = ComparisonWindowController(a: a, b: b)
    defer { controller.close() }
    controller.session.temporaryRoots = []
    controller.reload()
    try await settle(controller)
    let window = try #require(controller.window)
    #expect(window.isKeyWindow == false)

    // The frontmost document window is chosen; other windows are skipped.
    let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    #expect(PrismApplication.frontmostDocumentWindow(in: [other, window], isVisible: { _ in true }) === window)
    #expect(PrismApplication.frontmostDocumentWindow(in: [other, window], isVisible: { $0 === other }) == nil)

    controller.selectNextChange(nil)
    func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }
    let copyRight = item(#selector(ComparisonWindowController.copyToRight(_:)))
    let target = PrismApplication.target(forAction: copyRight.action!, in: window)
    #expect(target as AnyObject? === controller)
    #expect((target as? NSMenuItemValidation)?.validateMenuItem(copyRight) == true)
    #expect(PrismApplication.target(forAction: #selector(FolderScopeController.startCopyingFiles(_:)), in: window) == nil)

    // The Merge menu shows the text items for this window.
    let merge = try #require(MainMenuBuilder.make(target: NSObject()).item(withTitle: MainMenuBuilder.mergeMenuTitle)?.submenu)
    MergeMenuContext.update(merge) { PrismApplication.target(forAction: $0, in: window) != nil }
    #expect(merge.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map(\.title)
        == ["Copy to Right", "Copy to Left", "Reset Selection", "Keep Both (Left then Right)", "Keep Both (Right then Left)"])

    // Undo goes to the window, which uses the comparison's undo manager
    // and names the action in the menu title.
    _ = NSApp.sendAction(copyRight.action!, to: target, from: copyRight)
    try await settle(controller)
    #expect(PrismApplication.target(forAction: Selector(("undo:")), in: window) as AnyObject? === window)
    #expect(window.undoManager === controller.session.undoManager)
    #expect(window.undoManager?.undoMenuItemTitle == "Undo Copy to Right")
    let merged = try #require(controller.session.text(.b)?.bytes)

    // Routed Undo, then Redo, as the Edit menu sends them: each is
    // validated (and titled) by its target first, then sent.
    let undoItem = item(Selector(("undo:"))), redoItem = item(Selector(("redo:")))
    func press(_ menuItem: NSMenuItem) throws -> Bool {
        let target = try #require(PrismApplication.target(forAction: menuItem.action!, in: window))
        guard (target as? NSMenuItemValidation)?.validateMenuItem(menuItem) == true else { return false }
        return NSApp.sendAction(menuItem.action!, to: target, from: menuItem)
    }
    #expect(try press(undoItem))
    try await settle(controller)
    #expect(controller.session.text(.b)?.bytes != merged)
    #expect(window.undoManager?.canRedo == true)
    // A background refresh titles and enables Redo without opening the menu.
    let edit = NSMenu(title: "Edit")
    let staleRedo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "")
    staleRedo.target = window
    PrismApplication.refresh(edit)
    #expect(staleRedo.title == "Redo Copy to Right" && staleRedo.isEnabled)
    #expect(PrismApplication.target(forAction: redoItem.action!, in: window) as AnyObject? === window)
    #expect((window as NSMenuItemValidation).validateMenuItem(redoItem))
    #expect(redoItem.title == "Redo Copy to Right")
    #expect(try press(redoItem))
    try await settle(controller)
    #expect(controller.session.text(.b)?.bytes == merged)
    #expect(window.undoManager?.canUndo == true)
}

@MainActor
@Test func windowMergesUndoesSavesAndValidatesMenus() async throws {
    _ = NSApplication.shared
    let folder = try workFolder("window")
    let a = try copyFixture("a.swift", to: folder), b = try copyFixture("b.swift", to: folder)
    let controller = ComparisonWindowController(a: a, b: b)
    controller.session.temporaryRoots = []
    controller.reload()
    try await settle(controller)
    #expect(controller.bottomBar.changeLabel.stringValue == "Change 1 of 8")
    controller.selectNextChange(nil)
    #expect(controller.bottomBar.changeLabel.stringValue == "Change 2 of 8")

    func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }
    let copyRight = item(#selector(ComparisonWindowController.copyToRight(_:)))
    let reset = item(#selector(ComparisonWindowController.resetSelection(_:)))
    let save = item(#selector(ComparisonWindowController.saveComparison(_:)))
    #expect(controller.validateMenuItem(copyRight))
    #expect(!controller.validateMenuItem(reset))
    #expect(!controller.validateMenuItem(save))
    #expect(controller.bottomBar.mergeControl.isEnabled(forSegment: ComparisonWindowController.MergeSegment.copyToRight))

    controller.copyToRight(nil)
    try await settle(controller)
    var model = try #require(controller.blocksView.model)
    #expect(lineText(model, .b, 3) == lineText(model, .a, 2))
    #expect(controller.bottomBar.changeLabel.stringValue == "Change 2 of 8")
    #expect(controller.blocksView.selectedChange == 1)
    #expect(controller.window?.isDocumentEdited == true)
    #expect(controller.pathBar.sideLabels.b.hasPrefix("B ") && controller.pathBar.sideLabels.a == "A")
    #expect(controller.validateMenuItem(reset) && controller.validateMenuItem(save))
    let manager = try #require(controller.window.flatMap { controller.windowWillReturnUndoManager($0) })
    #expect(manager === controller.session.undoManager)

    manager.undo()
    try await settle(controller)
    model = try #require(controller.blocksView.model)
    #expect(lineText(model, .b, 3) == "/// Computes a friendly greeting for a user.")
    #expect(controller.window?.isDocumentEdited == false)
    manager.redo()
    try await settle(controller)
    model = try #require(controller.blocksView.model)
    #expect(lineText(model, .b, 3) == lineText(model, .a, 2))

    controller.saveComparison(nil)
    #expect(controller.window?.isDocumentEdited == false)
    #expect(String(decoding: try fileBytes(b), as: UTF8.self).contains("/// Computes greeting for a user."))
    #expect(try fileBytes(a) == fileBytes(Corpus.fixture("text/a.swift")))

    // Reset Selection puts B's line back (unsaved now).
    controller.resetSelection(nil)
    try await settle(controller)
    model = try #require(controller.blocksView.model)
    #expect(lineText(model, .b, 3) == "/// Computes a friendly greeting for a user.")
    #expect(controller.window?.isDocumentEdited == true)
    controller.revertComparisonToSaved(nil)
    try await settle(controller)
    #expect(controller.window?.isDocumentEdited == false)
    model = try #require(controller.blocksView.model)
    #expect(lineText(model, .b, 3) == lineText(model, .a, 2))
}

@MainActor
@Test func windowRefusesMergesIntoTemporaryCopies() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appending(path: "prism-m6-snapwin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let a = try copyFixture("a.swift", to: folder), b = try copyFixture("b.swift", to: folder)
    let controller = ComparisonWindowController(a: a, b: b)
    controller.reload()
    try await settle(controller)
    controller.selectNextChange(nil)
    controller.copyToRight(nil)
    try await settle(controller)
    #expect(controller.lastRefusal?.title.contains("b.swift") == true)
    #expect(controller.session.isDirty == false)
    let model = try #require(controller.blocksView.model)
    #expect(lineText(model, .b, 3) == "/// Computes a friendly greeting for a user.")
}

@MainActor
@Test func theEditorOpensOverTheBlockAndCommitsAsOneEdit() async throws {
    _ = NSApplication.shared
    let folder = try workFolder("editor")
    let a = try copyFixture("a.swift", to: folder), b = try copyFixture("b.swift", to: folder)
    let controller = ComparisonWindowController(a: a, b: b)
    controller.session.temporaryRoots = []
    controller.reload()
    try await settle(controller)
    let view = controller.blocksView
    let geometry = try #require(view.geometry(for: .b))
    // Row of B's line 4 (index 3): the comment of change 2.
    let row = try #require(geometry.rows.row(ofLine: 3, side: .b))
    let caret = TextSelection(pane: .b, anchor: TextPosition(row: row, offset: 4), head: TextPosition(row: row, offset: 4))
    #expect(view.onBeginEditing?(.b, caret, nil) == true)
    let editor = controller.editor
    let region = try #require(editor.region)
    #expect(region.side == .b && region.lines == 3 ..< 4)
    let textView = try #require(editor.textView)
    #expect(textView.layoutManager != nil) // TextKit 1
    #expect(textView.string == "/// Computes a friendly greeting for a user.")
    #expect(region.lines(from: "x") == "x\n")
    #expect(textView.selectedRange() == NSRange(location: 4, length: 0))
    #expect(textView.frame.minY == geometry.y(ofRow: row))
    #expect(textView.superview === view.paneB)
    // Merging is off while the editor is open (⌘→ moves the caret there).
    #expect(!controller.validateMenuItem(NSMenuItem(title: "", action: #selector(ComparisonWindowController.copyToRight(_:)),
                                                    keyEquivalent: "")))
    textView.insertText("edited ", replacementRange: NSRange(location: 4, length: 0))
    editor.commit()
    #expect(editor.textView == nil && textView.superview == nil)
    try await settle(controller)
    let model = try #require(view.model)
    #expect(lineText(model, .b, 3) == "/// edited Computes a friendly greeting for a user.")
    #expect(controller.session.undoManager.undoActionName == "Typing")
    #expect(controller.window?.isDocumentEdited == true)
    controller.session.undoManager.undo()
    try await settle(controller)
    #expect(controller.window?.isDocumentEdited == false)
}

// MARK: offscreen renders for the visual review (screens 04 and 05)

/// With PRISM_M06_SHOTS set, renders the window content (never shown on
/// screen) before and after Copy to Right, and with the editor open.
@MainActor
@Test func rendersMergeStatesOffscreen() async throws {
    guard let shots = ProcessInfo.processInfo.environment["PRISM_M06_SHOTS"], !shots.isEmpty else { return }
    _ = NSApplication.shared
    let folder = try workFolder("shots")
    let a = try copyFixture("a.swift", to: folder), b = try copyFixture("b.swift", to: folder)
    let controller = ComparisonWindowController(a: a, b: b)
    controller.session.temporaryRoots = []
    controller.blocksView.setMode(.blocks)
    controller.reload()
    try await settle(controller)
    let output = URL(filePath: shots, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    func shoot(_ name: String) throws {
        let view = try #require(controller.window?.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: output.appending(path: "\(name).png"))
    }
    controller.selectNextChange(nil)
    try shoot("m06-change2-selected")
    controller.copyToRight(nil)
    try await settle(controller)
    try shoot("m06-after-copy-to-right")
    let geometry = try #require(controller.blocksView.geometry(for: .b))
    let row = try #require(geometry.rows.row(ofLine: 6, side: .b))
    let caret = TextPosition(row: row, offset: 8)
    _ = controller.blocksView.onBeginEditing?(.b, TextSelection(pane: .b, anchor: caret, head: caret), nil)
    try shoot("m06-editor-open")
    controller.editor.commit()
}

// MARK: menus

/// One Merge menu serves every window: the items shown depend on the kind
/// of comparison in front, in the reference order, with no shortcut used
/// twice in a context.
@MainActor
@Test func mergeMenuShowsTheItemsOfTheFrontmostKind() throws {
    let menu = MainMenuBuilder.make(target: NSObject())
    let merge = try #require(menu.item(withTitle: MainMenuBuilder.mergeMenuTitle)?.submenu)
    func visible() -> [String] {
        merge.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "-" : $0.title }
    }
    func shortcuts() -> [String] {
        merge.items.filter { !$0.isHidden && !$0.isSeparatorItem }
            .map { "\($0.keyEquivalentModifierMask.rawValue):\($0.keyEquivalent)" }
    }
    let text = ["Copy to Right", "Copy to Left", "Reset Selection", "-",
                "Keep Both (Left then Right)", "Keep Both (Right then Left)"]
    let folder = ["Copy to Right", "Copy to Left", "Reset Selection", "-", "Start Copying Files"]

    MergeMenuContext.update(merge) { ComparisonWindowController.instancesRespond(to: $0) }
    #expect(visible() == text)
    #expect(Set(shortcuts()).count == shortcuts().count)
    #expect(merge.items.filter { !$0.isHidden && !$0.isSeparatorItem }
        .allSatisfy { ComparisonWindowController.instancesRespond(to: $0.action!) })

    MergeMenuContext.update(merge) { FolderScopeController.instancesRespond(to: $0) }
    #expect(visible() == folder)
    #expect(Set(shortcuts()).count == shortcuts().count)

    // No comparison in front: everything shows (and validates disabled).
    MergeMenuContext.update(merge) { _ in false }
    #expect(visible() == text + ["Start Copying Files"])
    #expect(merge.delegate === MergeMenuContext.shared)
}

@MainActor
@Test func mergeMenuHasTheShortcutsOfTheReference() throws {
    let menu = MainMenuBuilder.make(target: NSObject())
    let merge = try #require(menu.item(withTitle: MainMenuBuilder.mergeMenuTitle)?.submenu)
    func check(_ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags, _ action: Selector) throws {
        let item = try #require(merge.item(withTitle: title))
        #expect(item.keyEquivalent == key && item.keyEquivalentModifierMask == modifiers && item.action == action)
    }
    try check("Copy to Right", MainMenuBuilder.rightArrow, .command, #selector(ComparisonWindowController.copyToRight(_:)))
    try check("Copy to Left", MainMenuBuilder.leftArrow, .command, #selector(ComparisonWindowController.copyToLeft(_:)))
    try check("Keep Both (Left then Right)", MainMenuBuilder.rightArrow, [.command, .option],
              #selector(ComparisonWindowController.keepBothLeftFirst(_:)))
    try check("Keep Both (Right then Left)", MainMenuBuilder.leftArrow, [.command, .option],
              #selector(ComparisonWindowController.keepBothRightFirst(_:)))
    try check("Reset Selection", MainMenuBuilder.backspace, [.command, .option],
              #selector(ComparisonWindowController.resetSelection(_:)))
    let file = try #require(menu.item(withTitle: MainMenuBuilder.fileMenuTitle)?.submenu)
    #expect(file.item(withTitle: "Save")?.keyEquivalent == "s")
    let saveAll = try #require(file.item(withTitle: "Save All"))
    #expect(saveAll.keyEquivalent == "s" && saveAll.keyEquivalentModifierMask == [.command, .shift])
    #expect(file.item(withTitle: "Revert to Saved")?.action
        == #selector(ComparisonWindowController.revertComparisonToSaved(_:)))
}
