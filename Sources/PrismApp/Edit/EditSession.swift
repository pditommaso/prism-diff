// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import Foundation
import os
import PrismProtocol

/// The editable state of a two-way comparison: the current text of both
/// sides, what was last saved, the merge markers, undo and redo. It knows
/// nothing about views: after every change it calls `onChange`, and the
/// window re-diffs and repaints.
@MainActor
final class EditSession {
    /// Why an edit or a save was refused, in words for an alert.
    struct Refusal: Error, Equatable, CustomStringConvertible {
        enum Kind: Equatable, Sendable {
            case general
            /// The file changed on disk since it was read; saving needs
            /// `overwritingExternalChanges`.
            case changedOnDisk
            /// Saving would write characters that replaced unreadable
            /// input; a merge saves only when told to allow it.
            case lossy
        }

        var title: String
        var message: String
        var kind: Kind = .general
        var description: String { "\(title) \(message)" }
    }

    /// What to select once the comparison is rebuilt after a change.
    enum Focus: Equatable, Sendable {
        /// The change with this index (nil: keep the current one).
        case change(Int?)
        /// The change that covers these lines (a merged region).
        case region(a: Range<Int>, b: Range<Int>)
    }

    /// Identity of a file's content on disk, to notice changes made by
    /// someone else between reading and saving.
    struct FileStamp: Equatable, Sendable {
        var size: Int64
        var modified: timespec
        var inode: UInt64

        static func == (lhs: FileStamp, rhs: FileStamp) -> Bool {
            lhs.size == rhs.size && lhs.inode == rhs.inode
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
        }

        /// The stamp of the file `url` leads to; nil when it cannot be read.
        static func of(_ url: URL) -> FileStamp? {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            return FileStamp(size: Int64(info.st_size), modified: info.st_mtimespec, inode: UInt64(info.st_ino))
        }
    }

    private(set) var urls: (a: URL, b: URL)
    private(set) var texts: (a: LoadedText, b: LoadedText)?
    private var saved: (a: [UInt8], b: [UInt8]) = ([], [])
    /// The files as they were on disk when read or last saved.
    private var stamps: (a: FileStamp?, b: FileStamp?) = (nil, nil)
    /// Changes a merge choice was applied to, in current line numbers.
    private(set) var markers: [MergeMarker] = []
    let undoManager: UndoManager
    /// Folders whose files are temporary copies (a version-control tool's
    /// snapshot of a revision): merging or typing into them is refused.
    var temporaryRoots: [String]
    /// Sides explicitly marked as snapshots by whoever opened them.
    var snapshotSides: Set<DiffSide> = []

    /// Called after the text changed (an edit, a merge, undo or redo), with
    /// the change to select once the comparison is rebuilt.
    var onChange: ((_ focus: Focus) -> Void)?

    init(a: URL, b: URL, temporaryRoots: [String] = EditSession.defaultTemporaryRoots()) {
        urls = (a, b)
        self.temporaryRoots = temporaryRoots
        undoManager = UndoManager()
        undoManager.groupsByEvent = false
    }

    /// The temporary directory (`$TMPDIR`), with symbolic links resolved.
    nonisolated static func defaultTemporaryRoots() -> [String] {
        var roots: [String] = []
        for path in [NSTemporaryDirectory(), ProcessInfo.processInfo.environment["TMPDIR"] ?? ""] where !path.isEmpty {
            let resolved = URL(filePath: path, directoryHint: .isDirectory).resolvingSymlinksInPath().path
            let root = resolved.hasSuffix("/") ? resolved : resolved + "/"
            if !roots.contains(root) { roots.append(root) }
        }
        return roots
    }

    // MARK: state

    /// Takes freshly read files: they become the saved state, and undo
    /// history and markers are forgotten.
    func load(a: LoadedText, b: LoadedText, urls: (a: URL, b: URL)) {
        self.urls = urls
        texts = (a, b)
        saved = (a.bytes, b.bytes)
        stamps = (FileStamp.of(urls.a), FileStamp.of(urls.b))
        markers = []
        undoManager.removeAllActions()
    }

    /// A and B trade places (Swap A & B). History cannot follow the swap,
    /// so it is cleared; unsaved text and markers move with their files.
    func swap() {
        urls = (urls.b, urls.a)
        texts = texts.map { ($0.b, $0.a) }
        saved = (saved.b, saved.a)
        stamps = (stamps.b, stamps.a)
        markers = markers.map { MergeMarker(a: $0.b, b: $0.a, originalA: $0.originalB, originalB: $0.originalA,
                                            choice: $0.choice.mirrored) }
        undoManager.removeAllActions()
        snapshotSides = Set(snapshotSides.map { $0 == .a ? .b : .a })
    }

    func text(_ side: DiffSide) -> LoadedText? { side == .a ? texts?.a : texts?.b }

    /// True when the side differs from what is on disk.
    func isDirty(_ side: DiffSide) -> Bool {
        guard let texts else { return false }
        return side == .a ? texts.a.bytes != saved.a : texts.b.bytes != saved.b
    }

    var isDirty: Bool { isDirty(.a) || isDirty(.b) }

    /// Line ranges the merges made identical, for the model to show them as
    /// resolved changes.
    var resolvedRegions: [(a: Range<Int>, b: Range<Int>)] { markers.map { ($0.a, $0.b) } }

    // MARK: guards

    /// Why `side` may not be changed, or nil when it may.
    func refusal(toChange side: DiffSide) -> Refusal? {
        let url = side == .a ? urls.a : urls.b
        let name = url.lastPathComponent
        if isTemporary(url) || snapshotSides.contains(side) {
            return Refusal(title: "\u{201C}\(name)\u{201D} can\u{2019}t be changed.",
                           message: "It is a temporary copy made for this comparison, so changes to it would be lost. "
                               + "Copy changes into the other side instead.")
        }
        if text(side)?.format == nil {
            return Refusal(title: "\u{201C}\(name)\u{201D} can\u{2019}t be changed.",
                           message: "Prism could not read it in a text encoding it can write back, "
                               + "so it is shown read-only.")
        }
        return nil
    }

    /// True when `url` lies in one of the temporary folders.
    func isTemporary(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return temporaryRoots.contains { path.hasPrefix($0) }
    }

    // MARK: merging

    /// The marker that change `index` of `model` belongs to, if any.
    func marker(forChange index: Int, in model: ComparisonModel) -> Int? {
        guard index >= 0, index < model.changeCount else { return nil }
        let block = model.layout.blocks[model.layout.changes[index]]
        return markers.firstIndex { marker in
            func inside(_ range: Range<Int>, _ outer: Range<Int>) -> Bool {
                range.lowerBound >= outer.lowerBound && range.upperBound <= outer.upperBound
            }
            return inside(block.a, marker.a) && inside(block.b, marker.b)
        }
    }

    /// The marker Reset Selection undoes for change `index`: the one that
    /// contains it, else one that shares lines with it (after a merge the
    /// diff may line the text up differently around the merged lines).
    func resettableMarker(forChange index: Int, in model: ComparisonModel) -> Int? {
        if let inside = marker(forChange: index, in: model) { return inside }
        guard index >= 0, index < model.changeCount else { return nil }
        let block = model.layout.blocks[model.layout.changes[index]]
        func shares(_ x: Range<Int>, _ y: Range<Int>) -> Bool { x.overlaps(y) }
        return markers.firstIndex { shares(block.a, $0.a) || shares(block.b, $0.b) }
    }

    /// Applies `choice` to change `index` of `model` (which must show the
    /// current text) as one undoable step. A change that already took a
    /// choice starts again from its original lines.
    func merge(_ choice: MergeChoice, change index: Int, in model: ComparisonModel) throws(Refusal) {
        guard let texts, index >= 0, index < model.changeCount else { return }
        let block = model.layout.blocks[model.layout.changes[index]]
        let existing = marker(forChange: index, in: model)
        let lines: (a: Range<Int>, b: Range<Int>) = existing.map { (markers[$0].a, markers[$0].b) } ?? (block.a, block.b)
        let original: (a: [UInt8], b: [UInt8]) = existing.map { (markers[$0].originalA, markers[$0].originalB) }
            ?? (Self.bytes(of: lines.a, in: texts.a.bytes), Self.bytes(of: lines.b, in: texts.b.bytes))
        let result = choice.result(a: original.a, b: original.b)
        let currentA = Self.bytes(of: lines.a, in: texts.a.bytes)
        let currentB = Self.bytes(of: lines.b, in: texts.b.bytes)
        // Choosing again what is already there changes nothing.
        if result.a == currentA, result.b == currentB, existing.map({ markers[$0].choice == choice }) ?? false {
            return
        }
        for (side, changes) in [(DiffSide.a, result.a != currentA), (.b, result.b != currentB)] where changes {
            if let refusal = refusal(toChange: side) { throw refusal }
        }
        var others = markers
        if let existing { others.remove(at: existing) }
        var marker = MergeMarker(a: lines.a, b: lines.b, originalA: original.a, originalB: original.b, choice: choice)
        var newA = texts.a.bytes, newB = texts.b.bytes
        if result.a != currentA {
            let spliced = LineEdit(side: .a, lines: lines.a, text: result.a).apply(to: newA)
            newA = spliced.bytes
            others = others.compactMap { $0.shifted(side: .a, replacing: lines.a, with: spliced.lines.count) }
            marker.a = spliced.lines
        }
        if result.b != currentB {
            let spliced = LineEdit(side: .b, lines: lines.b, text: result.b).apply(to: newB)
            newB = spliced.bytes
            others = others.compactMap { $0.shifted(side: .b, replacing: lines.b, with: spliced.lines.count) }
            marker.b = spliced.lines
        }
        // Kept even when no line is left on either side (a copied insert
        // or deletion), so the change stays listed and can be reset.
        others.append(marker)
        others.sort { ($0.a.lowerBound, $0.b.lowerBound) < ($1.a.lowerBound, $1.b.lowerBound) }
        commit(a: newA, b: newB, markers: others, actionName: choice.title,
               focus: .region(a: marker.a, b: marker.b), undoFocus: .region(a: lines.a, b: lines.b))
    }

    /// Reset Selection: puts the change back to its original lines on both
    /// sides. Does nothing for a change no choice was applied to.
    func reset(change index: Int, in model: ComparisonModel) throws(Refusal) {
        guard let texts, let found = resettableMarker(forChange: index, in: model) else { return }
        let marker = markers[found]
        var restored = (a: marker.a, b: marker.b)
        var others = markers
        others.remove(at: found)
        var newA = texts.a.bytes, newB = texts.b.bytes
        if Self.bytes(of: marker.a, in: newA) != marker.originalA {
            if let refusal = refusal(toChange: .a) { throw refusal }
            let spliced = LineEdit(side: .a, lines: marker.a, text: marker.originalA).apply(to: newA)
            newA = spliced.bytes
            restored.a = spliced.lines
            others = others.compactMap { $0.shifted(side: .a, replacing: marker.a, with: spliced.lines.count) }
        }
        if Self.bytes(of: marker.b, in: newB) != marker.originalB {
            if let refusal = refusal(toChange: .b) { throw refusal }
            let spliced = LineEdit(side: .b, lines: marker.b, text: marker.originalB).apply(to: newB)
            newB = spliced.bytes
            restored.b = spliced.lines
            others = others.compactMap { $0.shifted(side: .b, replacing: marker.b, with: spliced.lines.count) }
        }
        commit(a: newA, b: newB, markers: others, actionName: "Reset Selection",
               focus: .region(a: restored.a, b: restored.b), undoFocus: .region(a: marker.a, b: marker.b))
    }

    /// True when Reset Selection has something to do for change `index`.
    func canReset(change index: Int, in model: ComparisonModel) -> Bool {
        resettableMarker(forChange: index, in: model) != nil
    }

    // MARK: free editing

    /// Replaces `lines` of `side` with text typed in the editor (lines
    /// separated by "\n", each ending with one except perhaps the last),
    /// written with the file's own line terminator. One undoable step.
    ///
    /// Each line keeps the terminator it had (a file may mix them); only
    /// lines added by the edit take the file's main terminator. Pasted
    /// CR LF, CR and U+2028 separators count as plain line breaks.
    func replaceLines(_ lines: Range<Int>, of side: DiffSide, with typed: String, selecting: Int?) throws(Refusal) {
        guard let texts else { return }
        let current = side == .a ? texts.a.bytes : texts.b.bytes
        let original = Self.bytes(of: lines, in: current)
        let replacement = LineText.retyped(typed, original: original, terminator: LineText.terminator(of: current))
        guard replacement != original else { return }
        if let refusal = refusal(toChange: side) { throw refusal }
        let spliced = LineEdit(side: side, lines: lines, text: replacement).apply(to: current)
        let shifted = markers.compactMap { $0.shifted(side: side, replacing: lines, with: spliced.lines.count) }
        commit(a: side == .a ? spliced.bytes : texts.a.bytes, b: side == .b ? spliced.bytes : texts.b.bytes,
               markers: shifted, actionName: "Typing", focus: .change(selecting), undoFocus: .change(selecting))
    }

    /// The text of `lines` as the editor shows it: terminators turned into
    /// "\n", the last line's kept only if it has one.
    func editableText(_ lines: Range<Int>, of side: DiffSide) -> String {
        guard let text = text(side) else { return "" }
        let bytes = Self.bytes(of: lines, in: text.bytes)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x0D {
                out.append(0x0A)
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 1 }
            } else {
                out.append(byte)
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: undo

    private struct Snapshot {
        var a: [UInt8]
        var b: [UInt8]
        var markers: [MergeMarker]
        var focus: Focus
    }

    /// Moves to the new text as one undo step. `focus` is selected after
    /// the change and redo, `undoFocus` after undo.
    private func commit(a: [UInt8], b: [UInt8], markers newMarkers: [MergeMarker], actionName: String,
                        focus: Focus, undoFocus: Focus) {
        guard let texts else { return }
        let before = Snapshot(a: texts.a.bytes, b: texts.b.bytes, markers: markers, focus: undoFocus)
        undoManager.beginUndoGrouping()
        restore(Snapshot(a: a, b: b, markers: newMarkers, focus: focus), undoing: before, actionName: actionName)
        undoManager.endUndoGrouping()
    }

    /// Moves to `state`, registering the way back to `previous`.
    private func restore(_ state: Snapshot, undoing previous: Snapshot, actionName: String) {
        guard var texts else { return }
        texts.a.bytes = state.a
        texts.b.bytes = state.b
        self.texts = texts
        markers = state.markers
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated {
                session.restore(previous, undoing: state, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
        onChange?(state.focus)
    }

    // MARK: saving

    /// Writes `side` to its file in its original encoding, byte order mark
    /// and line terminators. Callers ask first when the format does not
    /// round-trip (`SaveFormat.roundTrips`).
    ///
    /// A file that changed on disk since it was read (or last saved) is not
    /// overwritten unless `overwritingExternalChanges`: the refusal then
    /// has the kind `.changedOnDisk`.
    func save(_ side: DiffSide, overwritingExternalChanges: Bool = false) throws(Refusal) {
        guard let text = text(side) else { return }
        let url = side == .a ? urls.a : urls.b
        let name = url.lastPathComponent
        guard let format = text.format else {
            throw Refusal(title: "\u{201C}\(name)\u{201D} can\u{2019}t be saved.",
                          message: "Its text could not be read in an encoding Prism can write back.")
        }
        guard let bytes = format.encode(text.bytes) else {
            throw Refusal(title: "\u{201C}\(name)\u{201D} can\u{2019}t be saved.",
                          message: "Some characters can\u{2019}t be written in its encoding (\(format.encoding.name)).")
        }
        let recorded = side == .a ? stamps.a : stamps.b
        if !overwritingExternalChanges, let recorded, FileStamp.of(url) != recorded {
            throw Refusal(title: "\u{201C}\(name)\u{201D} was changed by another application.",
                          message: "It changed on disk after Prism read it. Saving would replace those changes.",
                          kind: .changedOnDisk)
        }
        do {
            try Self.write(bytes, to: url)
        } catch {
            PrismLog.ui.error("file not saved: \(error.message, privacy: .private)")
            throw Refusal(title: "\u{201C}\(name)\u{201D} can\u{2019}t be saved.", message: error.message)
        }
        if side == .a { saved.a = text.bytes } else { saved.b = text.bytes }
        if side == .a { stamps.a = FileStamp.of(url) } else { stamps.b = FileStamp.of(url) }
    }

    /// Why a file could not be written, naming the file the user knows.
    struct WriteError: Error, Equatable {
        var message: String
    }

    /// Replaces the file's content and flushes it to the disk, following a
    /// symbolic link to the real file. The new content goes to a temporary
    /// file next to it that then takes its place (keeping the file's
    /// permissions, owner and extended attributes); a file with several
    /// hard links, or in a folder that cannot be written, is written in
    /// place so that it stays the same file.
    nonisolated static func write(_ bytes: [UInt8], to url: URL) throws(WriteError) {
        let target = url.resolvingSymlinksInPath()
        let path = target.path
        let name = target.lastPathComponent
        func failure(_ what: String, _ code: Int32) -> WriteError {
            WriteError(message: "\(what) \u{201C}\(name)\u{201D}: \(String(cString: strerror(code))).")
        }
        var info = stat()
        guard stat(path, &info) == 0 else {
            if errno != ENOENT { throw failure("Could not read", errno) }
            try writeFile(bytes, at: path, flags: O_WRONLY | O_CREAT | O_EXCL, mode: 0o644, name: name)
            return
        }
        guard access(path, W_OK) == 0 else {
            throw WriteError(message: "You don\u{2019}t have permission to write \u{201C}\(name)\u{201D}.")
        }
        let folder = target.deletingLastPathComponent().path
        if info.st_nlink > 1 || access(folder, W_OK) != 0 {
            try writeFile(bytes, at: path, flags: O_WRONLY | O_TRUNC, mode: 0, name: name)
            return
        }
        let temporary = folder + "/.\(name).prism-\(UUID().uuidString)"
        try writeFile(bytes, at: temporary, flags: O_WRONLY | O_CREAT | O_EXCL, mode: info.st_mode & 0o7777, name: name)
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: URL(filePath: temporary))
        } catch {
            unlink(temporary)
            throw WriteError(message: "Could not replace \u{201C}\(name)\u{201D}: "
                + ((error as NSError).localizedFailureReason ?? (error as NSError).localizedDescription))
        }
    }

    /// Writes all of `bytes` to `path` and forces them to the disk.
    nonisolated private static func writeFile(_ bytes: [UInt8], at path: String, flags: Int32, mode: mode_t,
                                              name: String) throws(WriteError) {
        let fd = open(path, flags | O_CLOEXEC, mode)
        guard fd >= 0 else {
            throw WriteError(message: "Could not write \u{201C}\(name)\u{201D}: \(String(cString: strerror(errno))).")
        }
        var written = 0
        var code: Int32 = 0
        bytes.withUnsafeBytes { buffer in
            while written < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + written, buffer.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    code = errno
                    return
                }
                written += n
            }
        }
        if code == 0, fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { code = errno }
        close(fd)
        if code != 0 {
            if flags & O_EXCL != 0 { unlink(path) }
            throw WriteError(message: "Could not write \u{201C}\(name)\u{201D}: \(String(cString: strerror(code))).")
        }
    }

    // MARK: helpers

    /// The bytes of `lines` (terminators included) in `bytes`.
    nonisolated static func bytes(of lines: Range<Int>, in bytes: [UInt8]) -> [UInt8] {
        let starts = LineText.starts(bytes)
        let count = starts.count - 1
        let lower = min(max(lines.lowerBound, 0), count), upper = min(max(lines.upperBound, lower), count)
        return Array(bytes[starts[lower] ..< starts[upper]])
    }
}

extension MergeChoice {
    /// The same choice seen with A and B swapped.
    var mirrored: MergeChoice {
        switch self {
        case .copyToRight: .copyToLeft
        case .copyToLeft: .copyToRight
        case .keepBothLeftFirst: .keepBothRightFirst
        case .keepBothRightFirst: .keepBothLeftFirst
        }
    }
}
