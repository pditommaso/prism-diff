// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import DiffCore
import Foundation
import PrismIntegration
import PrismProtocol
import PrismTestSupport
import Testing
@testable import PrismApp

// Regression tests for the M7 review: an untouched editor never resolves a
// conflict, documents are never merged, quitting reports a resolved merge,
// whitespace preferences never change the result, lossy text is not saved
// silently, and a merge without a base keeps its common lines. No window is
// ever shown.

private func folder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "prism-m7-fix-\(UUID().uuidString)/\(name)",
                                                               directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes A, B and base (optional) and names an output that holds git's
/// conflict markers.
private func files(_ name: String, a: [UInt8], b: [UInt8], base: [UInt8]?, ext: String = "txt") throws -> MergeFiles {
    let dir = try folder(name)
    let urls = ["a", "b", "base"].map { dir.appending(path: "\($0).\(ext)") }
    try Data(a).write(to: urls[0])
    try Data(b).write(to: urls[1])
    if let base { try Data(base).write(to: urls[2]) }
    let output = dir.appending(path: "merged.\(ext)")
    try Data("<<<<<<< markers\n".utf8).write(to: output)
    return MergeFiles(a: urls[0], b: urls[1], base: base == nil ? nil : urls[2], output: output)
}

private func notes() throws -> MergeFiles {
    let source = Corpus.directory.appending(path: "merge/notes", directoryHint: .isDirectory)
    func read(_ name: String) throws -> [UInt8] { [UInt8](try Data(contentsOf: source.appending(path: name))) }
    return try files("notes", a: read("a.txt"), b: read("b.txt"), base: read("base.txt"))
}

@MainActor
private func controller(_ files: MergeFiles) async throws -> MergeWindowController {
    _ = NSApplication.shared
    let controller = MergeWindowController(files: files)
    controller.load()
    let deadline = ContinuousClock.now + .seconds(60)
    try await Task.sleep(for: .milliseconds(1))
    while controller.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    return controller
}

private func bytes(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }

// MARK: B1: an untouched editor never resolves a conflict

@MainActor
@Test func openingAndLeavingTheEditorKeepsTheConflictUnresolved() async throws {
    let files = try notes()
    let controller = try await controller(files)
    var outcome: Bool?
    controller.onFinish = { outcome = $0 }
    let conflict = try #require(controller.session.conflicts.first)
    controller.beginEditing(region: conflict)           // double click
    #expect(controller.editor?.string == "")
    // Asking whether the window may close changes nothing.
    #expect(controller.closeQuestion == .unresolvedConflicts)
    #expect(controller.editor != nil, "closeQuestion has no side effects")
    // Anything else (here: navigation, which commits) leaves it unresolved.
    controller.selectNextChange(nil)
    #expect(controller.editor == nil)
    #expect(controller.session.unresolvedCount == 1)
    #expect(controller.session.edits.isEmpty)
    #expect(!controller.saveComparison(nil) || !controller.session.isResolved)
    controller.answer(.unresolvedConflicts, .alertSecondButtonReturn)
    #expect(outcome == false)
}

@MainActor
@Test func emptyTextOverAPlaceholderIsNoEdit() throws {
    let session = MergeSession(files: try notes())
    let computed = try MergeSession.compute(files: session.files, source: ImportedTextSource())
    session.load(texts: computed.texts, result: computed.result)
    let conflict = try #require(session.conflicts.first)
    session.edit(region: conflict, text: "")
    #expect(session.unresolvedCount == 1 && session.edits.isEmpty)
    #expect(!session.undoManager.canUndo)
    session.edit(region: conflict, text: "line2 typed")
    #expect(session.unresolvedCount == 0)
}

@MainActor
@Test func windowShouldCloseCommitsATypedEditFirst() async throws {
    let files = try notes()
    let controller = try await controller(files)
    let conflict = try #require(controller.session.conflicts.first)
    controller.beginEditing(region: conflict)
    controller.editor?.string = "line2 by hand"
    _ = controller.windowShouldClose(controller.window!)    // asks: unsaved changes
    #expect(controller.session.unresolvedCount == 0)
    #expect(controller.pendingQuestion == .unsavedChanges)
}

// MARK: B2: documents are never merged

@MainActor
@Test(arguments: ["doc.rtf", "doc.docx", "doc.odt", "doc.doc", "doc.pdf"])
func documentsAreRefusedAndTheMergeEndsUnresolved(_ name: String) async throws {
    let source = [UInt8](try Data(contentsOf: Corpus.directory.appending(path: "encodings/\(name)")))
    let ext = (name as NSString).pathExtension
    let files = try files("doc-\(ext)", a: source, b: source, base: source, ext: ext)
    let before = try bytes(files.output)
    #expect(throws: (any Error).self) { try MergeSession.compute(files: files, source: ImportedTextSource()) }
    let controller = try await controller(files)
    var outcome: Bool?
    controller.onFinish = { outcome = $0 }
    #expect(!controller.showsMerge)
    #expect(controller.placeholder.message.contains("not a plain text file"))
    #expect(!controller.saveComparison(nil) || controller.session.result == nil)
    controller.window?.close()
    #expect(outcome == false)
    #expect(try bytes(files.output) == before, "the output is untouched")
}

@MainActor
@Test func binaryPropertyListsAreRefused() throws {
    let plist = try PropertyListSerialization.data(fromPropertyList: ["key": "value", "n": 1],
                                                   format: .binary, options: 0)
    let files = try files("plist", a: [UInt8](plist), b: [UInt8](plist), base: [UInt8](plist), ext: "plist")
    #expect(throws: (any Error).self) { try MergeSession.compute(files: files, source: ImportedTextSource()) }
}

// MARK: M1: quitting reports a resolved merge before the server stops

@MainActor
@Test func quittingAfterAResolvedSaveReportsResolvedToTheWaitingClient() async throws {
    let directory = URL(filePath: try {
        var template = Array("/tmp/prism-m7q.XXXXXX".utf8CString)
        guard let path = mkdtemp(&template) else { throw CocoaError(.fileWriteUnknown) }
        return String(cString: path)
    }(), directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sink = RecordingSink()
    let router = ChangesetRouter(sink: sink, snapshots: nil)
    let server = IPCServer(socketPath: directory.appending(path: "s.sock").path, router: router)
    try server.start()
    let files = try notes()
    let caller = CallerInfo(process: nil, name: "git", arguments: [], tool: .git, workingDirectory: directory.path)
    let invocation = Invocation(kind: .merge,
                                fileLists: [FileList(files: [files.a, files.b, files.base!].map {
                                    FileReference(path: $0.path, temporary: false)
                                })],
                                wait: true, caller: caller, mergeOutput: files.output.path)
    let socket = server.socketPath
    let event = Task.detached { () -> EventKind? in
        do {
        let (reply, connection) = try IPCClient(socketPath: socket).send(Request(operation: .open, invocation: invocation),
                                                                          keepOpen: true)
        guard reply.ok, let connection else { return nil }
        return try? connection.waitForEvent().kind
        } catch {
            return nil
        }
    }
    let deadline = ContinuousClock.now + .seconds(10)
    while sink.documents.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let document = try #require(sink.documents.first)

    let controller = try await controller(files)
    controller.onFinish = { router.mergeFinished(document.id, resolved: $0) }
    controller.copyToRight(nil)
    #expect(controller.saveComparison(nil))
    // What applicationWillTerminate does: finish the merges, then stop.
    controller.finishNow()
    server.stop()
    router.shutdown()
    let kind = await event.value
    #expect(kind == .mergeResolved)
    #expect(try String(contentsOf: files.output, encoding: .utf8) == "line1\nline2 main\nline3\n")
}

@MainActor
@Test func finishNowReportsOnceAndUnresolvedWhenNotSaved() async throws {
    let controller = try await controller(try notes())
    var outcomes: [Bool] = []
    controller.onFinish = { outcomes.append($0) }
    controller.copyToRight(nil)                 // resolved but not saved
    controller.finishNow()
    controller.window?.close()
    #expect(outcomes == [false])
}

// MARK: M2: whitespace never changes the result

@MainActor
@Test func whitespaceOnlyEditsAreKept() async throws {
    let base = "func f() {\n  // note\n  body()\n}\n".bytes
    let a = "func g() {\n  // note\n  body()\n}\n".bytes       // renames
    let b = "func f() {\n  // note\n    body()\n}\n".bytes     // re-indents
    let files = try files("whitespace", a: a, b: b, base: base)
    // The preference is not even read: MergeSession.compute has no
    // whitespace mode. (Changing the shared preference here would disturb
    // two-way tests running in parallel.)
    let controller = try await controller(files)
    #expect(!controller.bottomBar.ignoreWhitespaceButton.isEnabled)
    #expect(controller.session.unresolvedCount == 0)
    #expect(controller.saveComparison(nil))
    #expect(try bytes(files.output) == "func g() {\n  // note\n    body()\n}\n".bytes)
    controller.window?.close()
}

// MARK: M3: lossy text is not saved silently

@MainActor
@Test func lossyTextIsSavedOnlyWhenAllowed() async throws {
    // UTF-16LE with a BOM and a lone high surrogate on line 2.
    func utf16(_ units: [UInt16]) -> [UInt8] {
        [0xFF, 0xFE] + units.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }
    let text = Array("line1\n".utf16) + [0xD800] + Array("x\nline3\n".utf16)
    let a = utf16(text), b = utf16(text)
    let files = try files("lossy", a: a, b: b, base: a)
    let loaded = try ImportedTextSource().load(files.a)
    #expect(loaded.format?.roundTrips == false || loaded.isLossy)
    let before = try bytes(files.output)
    let controller = try await controller(files)
    #expect(!controller.saveComparison(nil))
    #expect(controller.lastRefusal?.kind == .lossy)
    #expect(try bytes(files.output) == before)
    #expect(controller.save(allowingLoss: true))
    #expect(try bytes(files.output) != before)
    controller.window?.close()
}

// MARK: minor: no base, common lines stay common

@MainActor
@Test func withoutABaseTheWindowShowsOneConflictPerDifference() async throws {
    let files = try files("nobase", a: "head\none\nmid\ntwo\ntail\n".bytes,
                          b: "head\nuno\nmid\ndos\ntail\n".bytes, base: nil)
    let controller = try await controller(files)
    #expect(controller.session.conflicts.count == 2)
    #expect(controller.conflictLabel == "Conflict 1 of 2 \u{26A0}")
    controller.window?.close()
}

private extension String {
    var bytes: [UInt8] { Array(utf8) }
}

// MARK: integration with the M10 shell

@MainActor
@Test func mergeWindowsAreDocumentWindowsForMenuRouting() async throws {
    let controller = try await controller(try notes())
    let window = try #require(controller.window)
    let other = NSWindow()
    #expect(PrismApplication.frontmostDocumentWindow(in: [other, window], isVisible: { _ in true }) === window)
    // Menu commands reach the merge window as if it were key.
    let target = PrismApplication.target(forAction: MainMenuBuilder.selectNextConflict, in: window)
    #expect(target as? MergeWindowController === controller)
    #expect(PrismApplication.target(forAction: #selector(MergeWindowController.copyToRight(_:)), in: window)
            as? MergeWindowController === controller)
    // View > Previous/Next Conflict (M10's items) are the merge window's actions.
    #expect(MainMenuBuilder.selectNextConflict == #selector(MergeWindowController.selectNextConflict(_:)))
    #expect(MainMenuBuilder.selectPreviousConflict == #selector(MergeWindowController.selectPreviousConflict(_:)))
    // The View menu shows the conflict items for a merge window.
    let menu = MainMenuBuilder.make(target: NSObject())
    let view = try #require(menu.item(withTitle: MainMenuBuilder.viewMenuTitle)?.submenu)
    ViewMenuContext.update(view) { MergeWindowController.instancesRespond(to: $0) }
    #expect(view.items.filter { $0.title.hasSuffix("Conflict") }.allSatisfy { !$0.isHidden })
    #expect(view.items.filter { $0.title.hasSuffix("Conflict") }.count == 2)
    controller.window?.close()
}

@MainActor
@Test func quitAndKeepWindowsNeverRestoresMerges() async throws {
    // Only document windows are saved; a merge window is not one, so it
    // never comes back (like a changeset, it belongs to a git run).
    let controller = try await controller(try notes())
    #expect(!(controller as AnyObject is DocumentWindowController))
    #expect(StateRestoration.save([], to: nil).isEmpty)
    controller.window?.close()
}
