// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import Foundation

/// The files of a three-way merge: the two versions, their common ancestor
/// (optional) and the file the result is saved to.
struct MergeFiles: Sendable, Equatable {
    var a: URL
    var b: URL
    var base: URL?
    var output: URL
}

/// The editable state of a three-way merge: the merge of A and B, the
/// choice made for each region, text typed over a region of the result,
/// what was last saved, and undo. It knows nothing about views: after every
/// change it calls `onChange` and the window redraws.
///
/// The result is A with every automatic choice applied, plus the user's
/// choices and edits. An unresolved conflict keeps A's lines in the text
/// that is saved (views show it as an empty placeholder).
@MainActor
final class MergeSession {
    typealias Choice = DiffCore.MergeChoice

    let files: MergeFiles
    private(set) var texts: (a: LoadedText, b: LoadedText, base: LoadedText?)?
    /// The merge as last computed, with the current choices.
    private(set) var result: Merge3Result?
    /// Text typed over a region of the result, by region index (it replaces
    /// whatever the region's choice takes).
    private(set) var edits: [Int: [UInt8]] = [:]
    /// The bytes last written to the output; nil while nothing was saved.
    private(set) var savedOutput: [UInt8]?
    let undoManager: UndoManager
    /// Called after the result changed (a choice, an edit, undo, redo or a
    /// new merge), with the region to select.
    var onChange: ((_ region: Int?) -> Void)?

    init(files: MergeFiles) {
        self.files = files
        undoManager = UndoManager()
        undoManager.groupsByEvent = false
    }

    // MARK: loading

    /// Why the files cannot be merged, in words for the window.
    struct Unmergeable: Error, LocalizedError {
        var errorDescription: String?
    }

    /// Reads the three files and merges them (off the main thread).
    ///
    /// Only plain text that can be written back is merged: a document
    /// (RTF, Word, OpenDocument, PDF, a property list) is shown as text
    /// converted from it, and saving that text over the output would
    /// destroy the file, so such a merge is refused (it then ends
    /// unresolved). The merge always compares bytes exactly: ignoring
    /// whitespace could take one side's whitespace-only edits for no edit
    /// and silently drop them from the result.
    nonisolated static func compute(files: MergeFiles,
                                    source: any TextSource) throws -> (texts: (LoadedText, LoadedText, LoadedText?), result: Merge3Result) {
        let a = try source.load(files.a), b = try source.load(files.b)
        let base = try files.base.map { try source.load($0) }
        for (url, text) in [(files.a, a), (files.b, b)] + (base.map { [(files.base!, $0)] } ?? []) where text.format == nil {
            throw Unmergeable(errorDescription: "\u{201C}\(url.lastPathComponent)\u{201D} is not a plain text file "
                + "(it is shown as text converted from a document), so Prism can\u{2019}t merge it: saving the result "
                + "would replace the document with plain text. Resolve this conflict with another tool; closing "
                + "this window leaves the merge unresolved.")
        }
        // Without a base every difference is a conflict.
        let result = try base.map { try Merge3.merge(base: $0.bytes, a: a.bytes, b: b.bytes) }
            ?? Merge3.mergeWithoutBase(a: a.bytes, b: b.bytes)
        return ((a, b, base), result)
    }

    /// Takes a fresh merge. Choices and edits made on an earlier merge of
    /// the same files (another whitespace mode) carry over to the regions
    /// that cover the same lines of A and B.
    func load(texts: (LoadedText, LoadedText, LoadedText?), result: Merge3Result) {
        var merged = result
        var carried: [Int: [UInt8]] = [:]
        if let old = self.result {
            for (index, region) in merged.regions.enumerated() where region.kind != .equal {
                guard let match = old.regions.firstIndex(where: { $0.aRange == region.aRange && $0.bRange == region.bRange })
                else { continue }
                if old.regions[match].kind != .equal, old.regions[match].choice != old.regions[match].autoChoice {
                    merged = merged.applying(choice: old.regions[match].choice, to: index)
                }
                if let edit = edits[match] { carried[index] = edit }
            }
        }
        self.texts = texts
        self.result = merged
        edits = carried
        undoManager.removeAllActions()
        onChange?(nil)
    }

    /// Forgets the merge, its choices, edits and undo history (Revert to
    /// Saved: the next `load` starts afresh).
    func discardChoices() {
        result = nil
        edits = [:]
        undoManager.removeAllActions()
    }

    // MARK: state

    /// Regions where A and B differ, as indices into `result.regions`.
    var differences: [Int] {
        result?.regions.indices.filter { result!.regions[$0].kind != .equal } ?? []
    }

    /// Regions that started as conflicts.
    var conflicts: [Int] {
        result?.regions.indices.filter { result!.regions[$0].kind == .conflict } ?? []
    }

    /// True when region `index` is a conflict with neither a choice nor an edit.
    func isUnresolved(_ index: Int) -> Bool {
        guard let region = result?.regions[index] else { return false }
        return region.isUnresolved && edits[index] == nil
    }

    var unresolvedCount: Int { conflicts.filter(isUnresolved).count }

    /// What region `index` puts in the result; `placeholder` when it is an
    /// unresolved conflict (the bytes are then A's lines, saved as they are).
    func output(ofRegion index: Int) -> (bytes: [UInt8], placeholder: Bool) {
        guard let result else { return ([], false) }
        if let edit = edits[index] { return (edit, false) }
        let range = result.regions[index].mergedRange
        let bytes = range.isEmpty ? [] : Array(result.merged[result.mergedLines.range(range.lowerBound).lowerBound
                                                             ..< result.mergedLines.range(range.upperBound - 1).upperBound])
        return (bytes, isUnresolved(index))
    }

    /// The text saved to the output: every region's output in order.
    var outputBytes: [UInt8] {
        guard let result else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(result.merged.count)
        let terminator = LineText.terminator(of: texts?.a.bytes ?? [])
        for index in result.regions.indices {
            let piece = output(ofRegion: index).bytes
            // Only a file's last line may lack a terminator: one that is
            // followed by more text gets one, so lines never run together.
            if !piece.isEmpty, !LineText.endsWithTerminator(out) { out += terminator }
            out += piece
        }
        return out
    }

    /// True when the result differs from what was last saved (or was never
    /// saved).
    var isDirty: Bool { result != nil && savedOutput != outputBytes }

    /// True when the merge may be reported as resolved: every conflict has
    /// a choice or an edit, and the result shown is the one saved.
    var isResolved: Bool { result != nil && unresolvedCount == 0 && savedOutput != nil && !isDirty }

    // MARK: changes

    private struct Snapshot {
        var result: Merge3Result
        var edits: [Int: [UInt8]]
    }

    /// Takes `choice` for region `index` (an edit there is dropped).
    func choose(_ choice: Choice, region index: Int) {
        guard let result, result.regions.indices.contains(index), result.regions[index].kind != .equal else { return }
        if result.regions[index].choice == choice, edits[index] == nil { return }
        let before = Snapshot(result: result, edits: edits)
        self.result = result.applying(choice: choice, to: index)
        edits[index] = nil
        commit(before, actionName: Self.title(of: choice), region: index)
    }

    /// Back to what the merge decided for region `index`: the automatic
    /// choice, or an unresolved conflict.
    func reset(region index: Int) {
        guard let result, result.regions.indices.contains(index), result.regions[index].kind != .equal else { return }
        let region = result.regions[index]
        guard region.choice != region.autoChoice || edits[index] != nil else { return }
        let before = Snapshot(result: result, edits: edits)
        self.result = result.applying(choice: region.autoChoice, to: index)
        edits[index] = nil
        commit(before, actionName: "Reset Selection", region: index)
    }

    /// True when region `index` has a choice or an edit to reset.
    func canReset(region index: Int) -> Bool {
        guard let result, result.regions.indices.contains(index) else { return false }
        let region = result.regions[index]
        return region.kind != .equal && (region.choice != region.autoChoice || edits[index] != nil)
    }

    /// Replaces what region `index` puts in the result with `text` (typed
    /// lines separated by "\n"; every line gets A's line terminator). Over
    /// an unresolved conflict, empty text is no edit: the conflict stays
    /// unresolved (only a choice or typed text resolves it).
    func edit(region index: Int, text: String) {
        guard let result, result.regions.indices.contains(index) else { return }
        let terminator = LineText.terminator(of: texts?.a.bytes ?? [])
        let typed = LineText.normalizingBreaks(text)
        let bytes = typed.isEmpty ? [] : LineText.converting(typed.hasSuffix("\n") ? typed : typed + "\n",
                                                             terminator: terminator)
        if isUnresolved(index) {
            guard !bytes.isEmpty else { return }
        } else {
            guard bytes != output(ofRegion: index).bytes else { return }
        }
        let before = Snapshot(result: result, edits: edits)
        edits[index] = bytes
        commit(before, actionName: "Typing", region: index)
    }

    /// The text of region `index` for the editor: its output lines joined
    /// by "\n", without the last terminator; empty for a placeholder.
    func editableText(ofRegion index: Int) -> String {
        let output = output(ofRegion: index)
        if output.placeholder { return "" }
        var text = String(decoding: output.bytes, as: UTF8.self)
        text = LineText.normalizingBreaks(text)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    private func commit(_ before: Snapshot, actionName: String, region: Int) {
        let after = Snapshot(result: result!, edits: edits)
        registerUndo(restoring: before, redo: after, actionName: actionName, region: region)
        onChange?(region)
    }

    private func registerUndo(restoring state: Snapshot, redo: Snapshot, actionName: String, region: Int) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated {
                session.result = state.result
                session.edits = state.edits
                session.registerUndo(restoring: redo, redo: state, actionName: actionName, region: region)
                session.onChange?(region)
            }
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    /// Menu title of a choice in a three-way merge.
    static func title(of choice: Choice) -> String {
        switch choice {
        case .none: "Reset Selection"
        case .a: "Choose Left"
        case .b: "Choose Right"
        case .aThenB: "Choose Both (Left First)"
        case .bThenA: "Choose Both (Right First)"
        }
    }

    // MARK: saving

    /// Writes the result to the output file, in A's encoding. A text that
    /// was read lossily (its encoding does not give back the original
    /// bytes, such as UTF-16 with a lone surrogate) is saved only when
    /// `allowingLoss`; otherwise the refusal has the kind `.lossy` and the
    /// window asks first.
    func save(allowingLoss: Bool = false) throws(EditSession.Refusal) {
        guard result != nil else { return }
        let name = files.output.lastPathComponent
        guard let a = texts?.a, let format = a.format else {
            throw EditSession.Refusal(title: "\u{201C}\(name)\u{201D} can\u{2019}t be saved.",
                                      message: "The merged files are not plain text Prism can write back.")
        }
        if !allowingLoss, !format.roundTrips || a.isLossy {
            throw EditSession.Refusal(
                title: "Saving \u{201C}\(name)\u{201D} may change characters Prism could not read.",
                message: "\(files.a.lastPathComponent) is not valid \(format.encoding.name): some characters were "
                    + "replaced when it was read, and saving writes the replacements.",
                kind: .lossy)
        }
        let text = outputBytes
        guard let bytes = format.encode(text) else {
            throw EditSession.Refusal(title: "\u{201C}\(name)\u{201D} can\u{2019}t be saved.",
                                      message: "Some characters can\u{2019}t be written in its encoding (\(format.encoding.name)).")
        }
        do {
            try EditSession.write(bytes, to: files.output)
        } catch {
            throw EditSession.Refusal(title: "\u{201C}\(name)\u{201D} can\u{2019}t be saved.", message: error.message)
        }
        savedOutput = text
    }
}
