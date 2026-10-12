// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import DiffCore

/// The swapped-in editor: a TextKit 1 `NSTextView` laid over the lines of
/// one block of one pane while they are edited. Input methods, spelling and
/// Services work in it as in any text view; the panes themselves stay
/// read-only drawings.
///
/// The editor commits (hands its text back) when it loses the keyboard
/// focus, on Escape, and on Command-Return. Undo inside the editor is its
/// own; the committed edit is then one step of the window's undo.
@MainActor
final class BlockEditor: NSObject, NSTextViewDelegate {
    /// What is being edited.
    struct Region: Equatable {
        /// The pane the editor sits in.
        var pane: DiffSide
        /// The side whose lines are edited (the pane's own side, except in
        /// Unified, whose single pane shows both).
        var side: DiffSide
        /// Lines replaced on commit (an empty range inserts there).
        var lines: Range<Int>
        /// Text of the lines as it was when editing started, terminators
        /// included ("\n").
        var original: String

        /// The editor shows the lines without the last line's terminator,
        /// so no empty line hangs below the block; it comes back on commit.
        /// An inserted block always ends its last line.
        var shown: String { original.hasSuffix("\n") ? String(original.dropLast()) : original }

        /// The lines to write for the editor's `text`.
        func lines(from text: String) -> String {
            if original.hasSuffix("\n") || (lines.isEmpty && !text.isEmpty) { return text + "\n" }
            return text
        }
    }

    /// A blocks of unchanged text longer than this is edited only over its
    /// visible part.
    static let maximumLines = 400

    weak var host: BlocksDiffView?
    /// The editable text of some lines of a side.
    var textProvider: ((DiffSide, Range<Int>) -> String)?
    /// Receives the finished text and where the caret was: a line of the
    /// region's side and a UTF-16 offset in it.
    var onCommit: ((Region, String, _ caret: (line: Int, offset: Int)) -> Void)?

    private(set) var region: Region?
    private(set) var textView: EditorTextView?
    private let localUndo = UndoManager()
    private var committing = false

    var isEditing: Bool { region != nil }

    init(host: BlocksDiffView) {
        self.host = host
    }

    // MARK: starting

    /// The lines that editing at `row` of `pane` covers: the block's lines
    /// of the row's side, or the visible part of a long unchanged block.
    func region(pane: DiffSide, row: Int) -> (side: DiffSide, lines: Range<Int>, rows: Range<Int>)? {
        guard let host, let model = host.model, let geometry = host.geometry(for: pane) else { return nil }
        let rows = geometry.rows
        switch rows.content(row) {
        case let .line(side, line, block):
            let blockLines = side == .a ? model.layout.blocks[block].a : model.layout.blocks[block].b
            var lines = blockLines
            if lines.count > Self.maximumLines {
                let visible = host.scrollView(for: pane).contentView.bounds
                let shown = geometry.rows(in: visible.minY, visible.maxY)
                var first = line, last = line
                for candidate in shown {
                    guard case let .line(s, l, b) = rows.content(candidate), s == side, b == block else { continue }
                    first = min(first, l)
                    last = max(last, l)
                }
                lines = first ..< last + 1
            }
            guard let top = rows.row(ofLine: lines.lowerBound, side: side),
                  let bottom = rows.row(ofLine: lines.upperBound - 1, side: side) else { return nil }
            return (side, lines, top ..< bottom + 1)
        case let .spacer(block, _, _):
            let side = pane
            let lines = side == .a ? model.layout.blocks[block].a : model.layout.blocks[block].b
            let blockRows = rows.rows(ofBlock: block)
            let top = lines.isEmpty ? blockRows.lowerBound
                : rows.row(ofLine: lines.lowerBound, side: side) ?? blockRows.lowerBound
            return (side, lines, top ..< blockRows.upperBound)
        case .trailer:
            let side = pane
            let end = model.side(side).lineCount
            return (side, end ..< end, rows.trailerRow ..< rows.trailerRow + 1)
        }
    }

    /// Opens the editor over the block at the selection's row, with the
    /// selection carried over and `event` (a key press) replayed into it.
    @discardableResult
    func begin(pane: DiffSide, selection: TextSelection, event: NSEvent?) -> Bool {
        // A pending edit is handed back first; the text is then re-diffed
        // and the rows the selection points at are stale.
        if commit() { return false }
        guard let host, let geometry = host.geometry(for: pane),
              let found = region(pane: pane, row: selection.head.row) else { return false }
        let region = Region(pane: pane, side: found.side, lines: found.lines,
                            original: textProvider?(found.side, found.lines) ?? "")
        let text = region.shown

        let metrics = host.metrics
        let paneView = host.textPane(pane)
        let top = geometry.y(ofRow: found.rows.lowerBound)
        let bottom = found.rows.isEmpty ? top + metrics.lineHeight : geometry.y(ofRow: found.rows.upperBound)
        let frame = NSRect(x: 0, y: top, width: paneView.bounds.width, height: max(bottom - top, metrics.lineHeight))

        let view = EditorTextView(frame: frame, metrics: metrics, palette: host.palette, wraps: host.wrapsLines)
        view.delegate = self
        view.setPlainText(text)
        view.onResign = { [weak self] in _ = self?.commit() }
        view.onFinish = { [weak self] in self?.finish() }
        view.setAccessibilityIdentifier("prism.editor")
        view.setAccessibilityLabel(region.side == .a ? "Editing A" : "Editing B")
        paneView.addSubview(view)
        self.region = region
        textView = view
        localUndo.removeAllActions()
        view.setSelectedRange(Self.range(of: selection, in: region, host: host, text: text))
        host.window?.makeFirstResponder(view)
        if let event { view.interpretKeyEvents([event]) }
        PerfLog.record("editorBegan", ["side": region.side == .a ? "a" : "b", "lines": region.lines.count])
        return true
    }

    /// The editor range matching a pane selection inside the region.
    private static func range(of selection: TextSelection, in region: Region, host: BlocksDiffView,
                              text: String) -> NSRange {
        let length = (text as NSString).length
        guard let geometry = host.geometry(for: region.pane) else { return NSRange(location: length, length: 0) }
        func offset(_ position: TextPosition) -> Int {
            guard case let .line(side, line, _) = geometry.rows.content(position.row), side == region.side,
                  region.lines.contains(line), let model = host.model else { return length }
            var total = 0
            for previous in region.lines.lowerBound ..< line {
                total += model.side(side).text(ofLine: previous).utf16.count + 1
            }
            return min(total + position.offset, length)
        }
        let lower = offset(selection.lower), upper = offset(selection.upper)
        return NSRange(location: min(lower, upper), length: abs(upper - lower))
    }

    // MARK: finishing

    /// Hands the text back (when it changed) and removes the editor.
    /// Returns true when changed text was handed back.
    @discardableResult
    func commit() -> Bool {
        guard !committing, let region, let view = textView else { return false }
        committing = true
        defer { committing = false }
        let text = view.string
        let caret = Self.caret(in: text, at: view.selectedRange().location, region: region)
        self.region = nil
        textView = nil
        view.onResign = nil
        view.delegate = nil
        if view.window?.firstResponder === view, let host {
            view.window?.makeFirstResponder(host.textPane(region.pane))
        }
        view.removeFromSuperview()
        let result = region.lines(from: text)
        PerfLog.record("editorCommitted", ["changed": result != region.original])
        guard result != region.original else { return false }
        onCommit?(region, result, caret)
        return true
    }

    /// The line (of the region's side) and offset of UTF-16 location
    /// `location` in the editor's `text`.
    static func caret(in text: String, at location: Int, region: Region) -> (line: Int, offset: Int) {
        let units = Array(text.utf16.prefix(max(0, location)))
        let breaks = units.filter { $0 == 0x0A }.count
        let lastBreak = units.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        return (region.lines.lowerBound + breaks, units.count - lastBreak)
    }

    /// Escape or Command-Return: commit and give the keyboard back to the pane.
    private func finish() {
        _ = commit()
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? { localUndo }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            finish()
            return true
        }
        return false
    }
}

/// The editor's text view: TextKit 1, plain text, the panes' font and row
/// height, no smart substitutions (this is source text).
@MainActor
final class EditorTextView: NSTextView {
    var onResign: (() -> Void)?
    var onFinish: (() -> Void)?

    init(frame: NSRect, metrics: TextMetrics, palette: ThemePalette, wraps: Bool) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: wraps ? frame.width : CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = wraps
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: frame, textContainer: container)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        smartInsertDeleteEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = !wraps
        minSize = frame.size
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        autoresizingMask = wraps ? [.width] : []
        textContainerInset = NSSize(width: metrics.textInset, height: 0)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = metrics.lineHeight
        style.maximumLineHeight = metrics.lineHeight
        let font = metrics.font
        // TextKit puts the extra leading above the glyphs; lift them to the
        // panes' baseline.
        let lift = max(0, metrics.lineHeight - metrics.baseline + font.descender)
        let textColor = NSColor(cgColor: palette.text) ?? .textColor
        typingAttributes = [.font: font, .foregroundColor: textColor, .paragraphStyle: style,
                            .baselineOffset: lift]
        defaultParagraphStyle = style
        self.font = font
        self.textColor = textColor
        drawsBackground = true
        backgroundColor = NSColor(cgColor: palette.background) ?? .textBackgroundColor
        insertionPointColor = textColor
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Replaces the text, in the typing attributes (plain text).
    func setPlainText(_ text: String) {
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: typingAttributes))
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let onResign {
            // After AppKit has finished moving the focus.
            DispatchQueue.main.async { onResign() }
        }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        // Command-Return ends editing.
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onFinish?()
            return
        }
        super.keyDown(with: event)
    }
}
