// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import DiffCore

/// A text position inside a pane: a row and a UTF-16 offset in the line
/// that row shows (0 on padding and trailer rows).
struct TextPosition: Comparable, Sendable {
    var row: Int
    var offset: Int

    static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        lhs.row != rhs.row ? lhs.row < rhs.row : lhs.offset < rhs.offset
    }
}

/// Selected text in one pane. `anchor` stays put while `head` follows the
/// mouse or a shift-click; the head's row is the current line.
struct TextSelection: Equatable, Sendable {
    var pane: DiffSide
    var anchor: TextPosition
    var head: TextPosition

    var lower: TextPosition { min(anchor, head) }
    var upper: TextPosition { max(anchor, head) }
    var isEmpty: Bool { anchor == head }
}

/// One find result: a UTF-16 range in a line of one side.
struct FindMatch: Equatable, Sendable {
    var side: DiffSide
    var line: Int
    var range: Range<Int>
}

/// What the panes highlight while the find bar is open.
struct FindHighlights {
    /// Matches by side and line.
    var lines: [DiffSide: [Int: [Range<Int>]]] = [:]
    /// The current match, drawn as a pill.
    var current: FindMatch?
    /// True while a search is active: everything else is veiled.
    var dims = false
    /// Identifies the set of matches in `lines`. Two values with the same
    /// non-negative id differ at most in `current`, so the view redraws only
    /// the old and new current match. -1 means "unknown": redraw all.
    var id = -1
}

/// The two-way text comparison, in one of three layouts:
///
///     Blocks:  [gutter A][text A] | [gutter B][text B]     padded, 1:1 scroll
///     Fluid:   [gutter A][text A] >connectors< [gutter B][text B]
///     Unified: [gutter A|B][text, A then B lines per change]
///
/// Every pane draws from a `PaneGeometry`: the rows of its layout and their
/// heights. In Blocks both panes share one geometry, so they always have
/// the same height and their clip views are locked together on both axes.
/// In Fluid each pane has its own and the scroll positions are mapped block
/// by block. Unified uses only the A pane and gutter.
///
/// With Wrap Lines on, a row is as many visual lines tall as its longest
/// side needs (`RowHeights`); with it off every row is one line.
@MainActor
final class BlocksDiffView: NSView {
    private(set) var model: ComparisonModel?
    private(set) var metrics: TextMetrics
    var theme: Theme {
        didSet { if theme != oldValue { themeChanged() } }
    }
    /// The theme's colours, made once per theme.
    private(set) var palette: ThemePalette

    private(set) var mode: ViewMode = .blocks
    private(set) var wrapsLines = false

    /// Selected change, an index into `model.layout.changes`.
    private(set) var selectedChange: Int?
    /// Called after the selection changes.
    var onSelectionChange: ((Int?) -> Void)?
    /// Called once, after both panes have drawn a model for the first time.
    var onFirstPaint: (() -> Void)?
    /// Asked to start editing in a pane (a double click or typing), with the
    /// text selection there and the key press that started it. Returns
    /// false when the pane cannot be edited.
    var onBeginEditing: ((_ pane: DiffSide, _ selection: TextSelection, _ event: NSEvent?) -> Bool)?

    /// Selected text (or the caret, when empty).
    private(set) var selection: TextSelection?
    /// Find results to highlight.
    var findHighlights = FindHighlights() {
        didSet {
            if findHighlights.id >= 0, findHighlights.id == oldValue.id, findHighlights.dims == oldValue.dims {
                // A step to another match: only two rows change.
                for match in [oldValue.current, findHighlights.current].compactMap({ $0 }) { invalidate(match) }
                return
            }
            if findHighlights.dims != oldValue.dims { updateScrollBackgrounds() }
            redrawAll()
            updateOverview()
        }
    }

    /// Redraws the row that shows `match`.
    private func invalidate(_ match: FindMatch) {
        let pane: DiffSide = mode == .unified ? .a : match.side
        guard let geometry = geometry(for: pane),
              let row = geometry.rows.row(ofLine: match.line, side: match.side) else { return }
        let view = textPane(pane)
        let top = geometry.y(ofRow: row) - 2
        view.setNeedsDisplay(NSRect(x: 0, y: top, width: view.bounds.width, height: geometry.height(ofRow: row) + 4))
    }

    let gutterA: GutterView
    let gutterB: GutterView
    let paneA: PaneTextView
    let paneB: PaneTextView
    let scrollA = NSScrollView()
    let scrollB = NSScrollView()
    let divider: DividerView
    /// Drags the divider between the panes.
    let splitHandle = SplitHandleView()
    /// A's share of the width the two panes take (Blocks and Fluid).
    private(set) var splitFraction: CGFloat = 0.5
    /// Called after the divider moves.
    var onSplitChange: (() -> Void)?
    let overviewA = OverviewScroller()
    let overviewB = OverviewScroller()
    private var syncing = false
    private var paintedSides: Set<Int> = []
    private var firstPaintReported = false
    private var gutterWidth: CGFloat = 40

    private(set) var geometryA: PaneGeometry?
    private(set) var geometryB: PaneGeometry?
    private var shaperA: LineShaper?
    private var shaperB: LineShaper?
    /// Wrap width of each pane in columns (when wrapping).
    private(set) var wrapColumns: (a: Int, b: Int) = (0, 0)

    /// Blocks: width of the divider; Fluid: width of the connector gutter.
    static let blocksDividerWidth: CGFloat = 2
    static let fluidGutterWidth: CGFloat = 70
    /// The narrowest a pane gets when the divider is dragged.
    static let minimumPaneWidth: CGFloat = 80
    /// Widest document, in points. A longer line is reachable with Wrap
    /// Lines; without it the view stops there (huge views and layers lose
    /// precision and memory).
    static let maximumDocumentWidth: CGFloat = 1_000_000

    init(font: NSFont, theme: Theme) {
        metrics = TextMetrics(font: font)
        self.theme = theme
        palette = ThemePalette(theme)
        gutterA = GutterView(side: .a)
        gutterB = GutterView(side: .b)
        paneA = PaneTextView(side: .a)
        paneB = PaneTextView(side: .b)
        divider = DividerView()
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        clipsToBounds = true
        for (scroll, pane, overview) in [(scrollA, paneA, overviewA), (scrollB, paneB, overviewB)] {
            scroll.verticalScroller = overview
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.drawsBackground = true
            scroll.backgroundColor = NSColor(cgColor: palette.background) ?? .textBackgroundColor
            scroll.documentView = pane
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                                                   name: NSView.boundsDidChangeNotification,
                                                   object: scroll.contentView)
            addSubview(scroll)
        }
        overviewA.host = self
        overviewB.host = self
        for view in [gutterA, gutterB, paneA, paneB, divider] as [any BlocksPart] {
            view.host = self
        }
        addSubview(gutterA)
        addSubview(divider)
        addSubview(gutterB)
        addSubview(splitHandle)
        splitHandle.onDrag = { [weak self] x in self?.dragSplit(to: x) }
        splitHandle.onReset = { [weak self] in self?.setSplitFraction(0.5) }
        applyModeVisibility()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Comparison")
        setAccessibilityIdentifier("prism.blocks")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // MARK: content

    /// Shows a new comparison. The selection moves to `initialChange` (or
    /// the first change), scrolled into view only if it starts below the
    /// top screenful. With `keepingPosition` the top line stays where it was
    /// (a re-diff of the same files).
    func show(_ model: ComparisonModel, initialChange: Int? = nil, keepingPosition: Bool = false) {
        let anchor = keepingPosition && self.model != nil ? scrollAnchor() : nil
        // A re-diff of the same files keeps the caret on its line.
        let caret = keepingPosition ? caretLine() : nil
        self.model = model
        paintedSides = []
        firstPaintReported = false
        selectedChange = nil
        selection = TextSelection(pane: .a, anchor: TextPosition(row: 0, offset: 0),
                                  head: TextPosition(row: 0, offset: 0))
        rebuildShapers()
        relayoutDocument()
        if let caret { placeCaret(pane: caret.pane, side: caret.side, line: caret.line, offset: caret.offset) }
        if let anchor {
            restore(anchor)
        } else {
            scroll(toY: 0)
        }
        // The text takes the keyboard (copy, the caret keys, VoiceOver's
        // current line) only when nothing else in the window has it, so a
        // reload never steals focus from the changeset sidebar, a folder
        // table or the find field.
        if let window, window.firstResponder == nil || window.firstResponder === window {
            window.makeFirstResponder(textPane(selection?.pane ?? .a))
        }
        if model.changeCount > 0 {
            let target = min(max((initialChange ?? 1) - 1, 0), model.changeCount - 1)
            if let geometry = geometryA {
                let rows = geometry.rows.rows(ofChange: target)
                let below = geometry.y(ofRow: rows.upperBound) > scrollA.contentView.bounds.maxY
                selectChange(target, scroll: anchor == nil && (initialChange != nil || below))
            }
        } else {
            onSelectionChange?(nil)
        }
        redrawAll()
    }

    /// The caret as a line of a side (nil on padding or the trailer row).
    func caretLine() -> (pane: DiffSide, side: DiffSide, line: Int, offset: Int)? {
        guard let selection, let geometry = geometry(for: selection.pane),
              selection.head.row < geometry.rows.count,
              case let .line(side, line, _) = geometry.rows.content(selection.head.row) else { return nil }
        return (selection.pane, side, line, selection.head.offset)
    }

    /// Puts an empty caret on `line` of `side` in `pane` (clamped to the
    /// text), without scrolling.
    func placeCaret(pane: DiffSide, side: DiffSide, line: Int, offset: Int) {
        guard let model, let geometry = geometry(for: pane) else { return }
        let count = model.side(side).lineCount
        guard count > 0 || geometry.rows.count > 0 else { return }
        let clamped = min(max(line, 0), max(count - 1, 0))
        guard let row = geometry.rows.row(ofLine: clamped, side: side) else { return }
        let length = count > 0 ? model.side(side).text(ofLine: clamped).utf16.count : 0
        let position = TextPosition(row: row, offset: min(max(offset, 0), length))
        setSelection(TextSelection(pane: pane, anchor: position, head: position))
    }

    /// Forgets the comparison (after a failed reload): nothing is drawn and
    /// navigation does nothing.
    func clear() {
        model = nil
        geometryA = nil
        geometryB = nil
        shaperA = nil
        shaperB = nil
        selectedChange = nil
        selection = nil
        findHighlights = FindHighlights()
        redrawAll()
    }

    /// Switches the layout, keeping the top line and the selected change.
    func setMode(_ newMode: ViewMode) {
        guard newMode != mode else { return }
        let anchor = model != nil ? scrollAnchor() : nil
        mode = newMode
        selection = selection.map { _ in
            TextSelection(pane: .a, anchor: TextPosition(row: 0, offset: 0), head: TextPosition(row: 0, offset: 0))
        }
        applyModeVisibility()
        relayoutDocument()
        if let anchor { restore(anchor) }
        if let selectedChange, let model, selectedChange < model.changeCount {
            onSelectionChange?(selectedChange)
        }
        redrawAll()
    }

    /// Turns line wrapping on or off, keeping the top line.
    func setWrapsLines(_ wraps: Bool) {
        guard wraps != wrapsLines else { return }
        let anchor = model != nil ? scrollAnchor() : nil
        wrapsLines = wraps
        relayoutDocument()
        if let anchor { restore(anchor) }
        redrawAll()
    }

    /// Changes the text font, keeping the top line, the part of it that was
    /// scrolled past and the first visible column.
    func setFont(_ font: NSFont) {
        guard font != metrics.font else { return }
        let anchor = model != nil ? scrollAnchor() : nil
        let column = scrollA.contentView.bounds.minX / metrics.charWidth
        metrics = TextMetrics(font: font)
        gutterA.resetCache()
        gutterB.resetCache()
        rebuildShapers()
        relayoutDocument()
        if let anchor {
            restore(anchor, x: (column * metrics.charWidth).rounded())
        }
        redrawAll()
    }

    /// The area below the text takes the background, veiled while find
    /// dims everything but the matches.
    private func updateScrollBackgrounds() {
        var color = NSColor(cgColor: palette.background) ?? .textBackgroundColor
        if findHighlights.dims, let veil = NSColor(cgColor: palette.findDim) {
            color = color.blended(withFraction: veil.alphaComponent, of: .black) ?? color
        }
        for scroll in [scrollA, scrollB] { scroll.backgroundColor = color }
    }

    private func themeChanged() {
        palette = ThemePalette(theme)
        updateScrollBackgrounds()
        updateOverview()
        redrawAll()
    }

    private func rebuildShapers() {
        guard let model else { return }
        shaperA = LineShaper(text: model.a, metrics: metrics)
        shaperB = LineShaper(text: model.b, metrics: metrics)
    }

    /// The shaper of one side's text.
    func shaper(for side: DiffSide) -> LineShaper? { side == .a ? shaperA : shaperB }

    /// The geometry of the pane on `side` (Unified uses only A).
    func geometry(for pane: DiffSide) -> PaneGeometry? { pane == .a ? geometryA : geometryB }

    func scrollView(for pane: DiffSide) -> NSScrollView { pane == .a ? scrollA : scrollB }

    func textPane(_ pane: DiffSide) -> PaneTextView { pane == .a ? paneA : paneB }

    /// Vertical offset of the pane on `side`.
    func scrollY(of pane: DiffSide) -> CGFloat { scrollView(for: pane).contentView.bounds.minY }

    private func applyModeVisibility() {
        let twoPanes = mode != .unified
        scrollB.isHidden = !twoPanes
        gutterB.isHidden = !twoPanes
        divider.isHidden = !twoPanes
        splitHandle.isHidden = !twoPanes
        // One vertical scroller, at the right edge of the window: B's in
        // the two-pane layouts (A follows it), A's in Unified.
        scrollA.hasVerticalScroller = !twoPanes
        scrollB.hasVerticalScroller = twoPanes
        gutterA.needsDisplay = true
        needsLayout = true
    }

    // MARK: geometry

    /// Rebuilds the rows and heights, sizes the documents and lays out.
    private func relayoutDocument() {
        guard let model else { return }
        let maxNumber = max(model.a.lineCount, model.b.lineCount) + 1
        gutterWidth = metrics.gutterWidth(maxNumber: maxNumber)
        // Unified: two number columns, each with room for an A or B mark.
        if mode == .unified { gutterWidth = (gutterWidth + 10) * 2 }
        // The old rows belong to the old model: nothing may use them while
        // the subviews are laid out for the new one.
        geometryA = nil
        geometryB = nil
        needsLayout = true
        layoutSubtreeIfNeeded()
        rebuildGeometry()
        sizeDocuments()
        paneA.invalidateAccessibility()
        paneB.invalidateAccessibility()
    }

    /// Wrap width in columns of a pane whose text area is `width` wide.
    private func columns(forWidth width: CGFloat) -> Int {
        max(8, Int(floor((width - metrics.textInset * 2) / metrics.charWidth)))
    }

    /// Width of the text area of a scroll view, from its frame: during
    /// layout the clip view has not been resized yet. The vertical scroller
    /// is always counted, so wrapped text never needs a horizontal one.
    private func textWidth(of view: NSScrollView) -> CGFloat {
        let scroller = view.hasVerticalScroller
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: view.verticalScroller?.scrollerStyle ?? .legacy)
            : 0
        return max(view.frame.width - scroller, 0)
    }

    private func rebuildGeometry() {
        guard let model else {
            geometryA = nil
            geometryB = nil
            return
        }
        let layout = model.layout
        let counts = (a: model.a.lineCount, b: model.b.lineCount)
        let kinds: (PaneRows.Kind, PaneRows.Kind) = switch mode {
        case .blocks: (.blocks(.a), .blocks(.b))
        case .fluid: (.fluid(.a), .fluid(.b))
        case .unified: (.unified, .unified)
        }
        let rowsA = PaneRows(kind: kinds.0, layout: layout, lineCounts: counts)
        let rowsB = PaneRows(kind: kinds.1, layout: layout, lineCounts: counts)
        guard wrapsLines else {
            wrapColumns = (0, 0)
            geometryA = PaneGeometry(rows: rowsA, heights: RowHeights(uniform: rowsA.count), metrics: metrics)
            geometryB = PaneGeometry(rows: rowsB, heights: RowHeights(uniform: rowsB.count), metrics: metrics)
            return
        }
        let columnsA = columns(forWidth: textWidth(of: scrollA))
        let columnsB = mode == .unified ? columnsA : columns(forWidth: textWidth(of: scrollB))
        wrapColumns = (columnsA, columnsB)
        // Visual lines of every line, in one tight pass per side.
        let linesA = visualLines(of: .a, columns: columnsA), linesB = visualLines(of: .b, columns: columnsB)
        let heights = WrapHeights { side, line in side == .a ? linesA[line] : linesB[line] }
        switch mode {
        case .blocks:
            let shared = heights.blocks(layout)
            geometryA = PaneGeometry(rows: rowsA, heights: shared, metrics: metrics)
            geometryB = PaneGeometry(rows: rowsB, heights: shared, metrics: metrics)
        case .fluid:
            geometryA = PaneGeometry(rows: rowsA, heights: heights.fluid(.a, count: counts.a), metrics: metrics)
            geometryB = PaneGeometry(rows: rowsB, heights: heights.fluid(.b, count: counts.b), metrics: metrics)
        case .unified:
            let unified = heights.unified(layout)
            geometryA = PaneGeometry(rows: rowsA, heights: unified, metrics: metrics)
            geometryB = PaneGeometry(rows: rowsB, heights: unified, metrics: metrics)
        }
    }

    /// Visual lines that line `line` of `side` takes (1 without wrapping):
    /// from its columns when it is monospaced ASCII, from its measured
    /// width otherwise.
    func wrappedHeight(side: DiffSide, line: Int) -> Int {
        guard wrapsLines, let model else { return 1 }
        let columns = side == .a ? wrapColumns.a : wrapColumns.b
        let text = model.side(side)
        if text.lineIsASCII[line] { return WrapHeights.lines(Int(text.lineColumns[line]), columns) }
        guard let shaper = shaper(for: side) else { return 1 }
        return WrapHeights.lines(width: shaper.measuredWidth(ofLine: line), wrap: CGFloat(columns) * metrics.charWidth)
    }

    /// `wrappedHeight` for every line of a side, wrapped at `columns`.
    private func visualLines(of side: DiffSide, columns: Int) -> [Int] {
        guard let model else { return [] }
        let text = model.side(side)
        let wrap = CGFloat(columns) * metrics.charWidth
        var result = [Int](repeating: 1, count: text.lineCount)
        text.lineColumns.withUnsafeBufferPointer { widths in
            text.lineIsASCII.withUnsafeBufferPointer { ascii in
                for line in 0 ..< widths.count {
                    let width = Int(widths[line])
                    if ascii[line] {
                        if width > columns { result[line] = (width + columns - 1) / columns }
                    } else if let shaper = shaper(for: side) {
                        result[line] = WrapHeights.lines(width: shaper.measuredWidth(ofLine: line), wrap: wrap)
                    }
                }
            }
        }
        return result
    }

    /// Where wrapped visual line `k` of a line starts and ends, in unwrapped
    /// x: at the first character that starts at or after `k × width`, so a
    /// character is never split between two visual lines.
    func wrapSlice(_ k: Int, side: DiffSide, line: Int, pane: DiffSide) -> Range<CGFloat>? {
        guard wrapsLines, let shaper = shaper(for: side) else { return nil }
        let width = CGFloat(pane == .a ? wrapColumns.a : wrapColumns.b) * metrics.charWidth
        guard width > 0 else { return nil }
        let shaped = shaper.line(line)
        let count = wrappedHeight(side: side, line: line)
        if shaped.isASCII {
            // Monospaced: slices fall exactly on character cells.
            let end = k + 1 < count ? CGFloat(k + 1) * width : .greatestFiniteMagnitude
            return CGFloat(k) * width ..< end
        }
        func start(_ index: Int) -> CGFloat {
            if index <= 0 { return 0 }
            let target = CGFloat(index) * width
            var offset = shaper.offset(atX: target, in: shaped, line: line)
            var x = shaper.x(ofOffset: offset, in: shaped, line: line)
            if x < target - 0.01, offset < shaped.utf16Count {
                offset = shaper.snapForward(offset + 1, in: shaped, line: line)
                x = shaper.x(ofOffset: offset, in: shaped, line: line)
            }
            // Right-to-left runs place offsets out of order: there, slice
            // at the plain width.
            return x >= target - 0.01 && x <= target + metrics.charWidth * 4 ? x : target
        }
        let from = start(k)
        let to = k + 1 < count ? start(k + 1) : .greatestFiniteMagnitude
        return from ..< max(from, to)
    }

    private func sizeDocuments() {
        guard let geometryA, let geometryB, let model else { return }
        var clipA = scrollA.contentView.bounds.width, clipB = scrollB.contentView.bounds.width
        let width: CGFloat
        if wrapsLines {
            width = 0
            clipA = textWidth(of: scrollA)
            clipB = textWidth(of: scrollB)
        } else {
            let columns = max(model.a.maxColumns, model.b.maxColumns) + 4
            width = min(metrics.textInset * 2 + CGFloat(columns) * metrics.charWidth, Self.maximumDocumentWidth)
        }
        // Blocks panes scroll sideways together, so they share a width;
        // wrapped panes are exactly as wide as their own clip views.
        let shared = mode == .blocks && !wrapsLines
        let round: (CGFloat) -> CGFloat = wrapsLines ? { floor($0) } : { ceil($0) }
        let sizeA = NSSize(width: round(max(width, shared ? max(clipA, clipB) : clipA)),
                           height: geometryA.documentHeight)
        let sizeB = NSSize(width: round(max(width, shared ? max(clipA, clipB) : clipB)),
                           height: geometryB.documentHeight)
        if paneA.frame.size != sizeA { paneA.setFrameSize(sizeA) }
        if paneB.frame.size != sizeB { paneB.setFrameSize(sizeB) }
        updateOverview()
    }

    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        switch mode {
        case .blocks, .fluid:
            let middle = middleWidth
            let paneWidth = paneWidthA(forWidth: width)
            let gutter = min(gutterWidth, max(paneWidth - 20, 0))
            gutterA.frame = NSRect(x: 0, y: 0, width: gutter, height: height)
            scrollA.frame = NSRect(x: gutter, y: 0, width: max(paneWidth - gutter, 0), height: height)
            divider.frame = NSRect(x: paneWidth, y: 0, width: middle, height: height)
            // A thin divider gets a wider grip; the Fluid gutter is all grip.
            let grip = max(middle, 8)
            splitHandle.frame = NSRect(x: paneWidth + floor((middle - grip) / 2), y: 0, width: grip, height: height)
            gutterB.frame = NSRect(x: paneWidth + middle, y: 0, width: gutter, height: height)
            scrollB.frame = NSRect(x: paneWidth + middle + gutter, y: 0,
                                   width: max(width - paneWidth - middle - gutter, 0), height: height)
        case .unified:
            let gutter = min(gutterWidth, max(width - 40, 0))
            gutterA.frame = NSRect(x: 0, y: 0, width: gutter, height: height)
            scrollA.frame = NSRect(x: gutter, y: 0, width: max(width - gutter, 0), height: height)
        }
        if wrapsLines, model != nil {
            let columnsA = columns(forWidth: textWidth(of: scrollA))
            let columnsB = mode == .unified ? columnsA : columns(forWidth: textWidth(of: scrollB))
            if (columnsA, columnsB) != wrapColumns {
                let anchor = scrollAnchor()
                rebuildGeometry()
                sizeDocuments()
                restore(anchor)
                redrawAll()
                paneA.invalidateAccessibility()
                paneB.invalidateAccessibility()
                return
            }
        }
        sizeDocuments()
    }

    private var middleWidth: CGFloat { mode == .blocks ? Self.blocksDividerWidth : Self.fluidGutterWidth }

    /// Width of the A pane, gutter included, when the view is `width` wide.
    private func paneWidthA(forWidth width: CGFloat) -> CGFloat {
        let available = max(width - middleWidth, 0)
        let minimum = min(Self.minimumPaneWidth, floor(available / 2))
        return min(max(floor(available * splitFraction), minimum), available - minimum)
    }

    /// x of the middle of the divider when the view is `width` wide.
    func splitX(forWidth width: CGFloat) -> CGFloat {
        guard mode != .unified else { return floor((width - 1) / 2) }
        return paneWidthA(forWidth: width) + floor(middleWidth / 2)
    }

    func setSplitFraction(_ fraction: CGFloat) {
        let clamped = min(max(fraction, 0), 1)
        guard clamped != splitFraction else { return }
        splitFraction = clamped
        needsLayout = true
        onSplitChange?()
    }

    /// Moves the divider's middle to `x`.
    private func dragSplit(to x: CGFloat) {
        let available = bounds.width - middleWidth
        guard available > 0 else { return }
        setSplitFraction((x - middleWidth / 2) / available)
    }

    func redrawAll() {
        for view in [gutterA, gutterB, paneA, paneB, divider, overviewA, overviewB] as [NSView] {
            view.needsDisplay = true
        }
    }

    // MARK: scrolling

    /// The vertical offset of the A pane (shared with B in Blocks).
    var scrollY: CGFloat { scrollA.contentView.bounds.minY }

    /// Scrolls both panes to the left edge and to `y` (clamped) in A; B
    /// follows (1:1 in Blocks, block by block in Fluid).
    func scroll(toY y: CGFloat) {
        scroll(scrollA, to: NSPoint(x: 0, y: y))
        mirror(from: scrollA, to: scrollB)
    }

    private func scroll(_ view: NSScrollView, to point: NSPoint) {
        let clip = view.contentView
        let document = view.documentView?.frame.size ?? .zero
        let maxY = max(0, document.height - clip.bounds.height)
        let maxX = max(0, document.width - clip.bounds.width)
        let target = NSPoint(x: min(max(0, point.x), maxX).rounded(), y: min(max(0, point.y), maxY).rounded())
        clip.scroll(to: target)
        view.reflectScrolledClipView(clip)
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        guard let clip = note.object as? NSClipView else { return }
        if !syncing {
            if clip === scrollA.contentView { mirror(from: scrollA, to: scrollB) }
            else if clip === scrollB.contentView { mirror(from: scrollB, to: scrollA) }
        }
        gutterA.needsDisplay = true
        gutterB.needsDisplay = true
        divider.needsDisplay = true
    }

    /// Copies one pane's scroll position to the other: both axes 1:1 in
    /// Blocks; in Fluid x 1:1 and y mapped through the block under the top
    /// edge, proportionally. Unified has one pane.
    private func mirror(from source: NSScrollView, to target: NSScrollView) {
        guard mode != .unified else { return }
        var origin = source.contentView.bounds.origin
        if mode == .fluid {
            let from: DiffSide = source === scrollA ? .a : .b
            origin.y = fluidCounterpart(ofY: origin.y, from: from).rounded()
        }
        guard target.contentView.bounds.origin != origin else { return }
        syncing = true
        defer { syncing = false }
        target.contentView.scroll(to: origin)
        target.reflectScrolledClipView(target.contentView)
    }

    /// Fluid scroll sync: the y in the other pane that corresponds to `y`
    /// in pane `side`. Inside a block, the same fraction of the block's
    /// height on the other side; a block that is empty on the other side
    /// pins it at the insertion point.
    func fluidCounterpart(ofY y: CGFloat, from side: DiffSide) -> CGFloat {
        guard let source = geometry(for: side), let target = geometry(for: side == .a ? .b : .a),
              let model else { return y }
        let row = source.row(atY: y)
        if row < 0 { return y }
        guard let block = source.rows.block(atRow: row) else {
            // Trailer and beyond: keep the same distance below the last line.
            let trailer = source.rows.trailerRow
            return target.y(ofRow: target.rows.trailerRow) + (y - source.y(ofRow: trailer))
        }
        let blockRows = model.layout.blocks[block]
        let own = side == .a ? blockRows.a : blockRows.b
        let other = side == .a ? blockRows.b : blockRows.a
        let top = source.y(ofRow: own.lowerBound), bottom = source.y(ofRow: own.upperBound)
        let fraction = bottom > top ? (y - top) / (bottom - top) : 0
        let otherTop = target.y(ofRow: other.lowerBound), otherBottom = target.y(ofRow: other.upperBound)
        return otherTop + fraction * (otherBottom - otherTop)
    }

    /// Where the view is: the line at the top of the A pane, the part of
    /// it scrolled past, and the horizontal offset.
    struct ScrollAnchor {
        var side: DiffSide
        var line: Int?
        var row: Int
        var fraction: CGFloat
        var x: CGFloat
    }

    func scrollAnchor() -> ScrollAnchor {
        let x = scrollA.contentView.bounds.minX
        guard let geometry = geometryA else { return ScrollAnchor(side: .a, line: nil, row: 0, fraction: 0, x: x) }
        let y = scrollY + metrics.topInset
        let row = max(0, min(geometry.row(atY: y), geometry.rows.count - 1))
        let top = geometry.y(ofRow: row), height = geometry.height(ofRow: row)
        let fraction = height > 0 ? max(0, min(1, (y - top) / height)) : 0
        if case let .line(side, line, _) = geometry.rows.content(row) {
            return ScrollAnchor(side: side, line: line, row: row, fraction: fraction, x: x)
        }
        return ScrollAnchor(side: .a, line: nil, row: row, fraction: fraction, x: x)
    }

    func restore(_ anchor: ScrollAnchor, x: CGFloat? = nil) {
        guard let geometry = geometryA else { return }
        var row = anchor.row
        if let line = anchor.line {
            if let found = geometry.rows.row(ofLine: line, side: anchor.side) {
                row = found
            } else if let model, let block = model.layout.block(ofLine: line, side: anchor.side),
                      let other = geometry.rows.rows(ofBlock: block).first {
                // That side is not shown in this pane (Fluid B line seen
                // from A): use its block.
                row = other
            }
        }
        row = max(0, min(row, geometry.rows.count - 1))
        let y = geometry.y(ofRow: row) + anchor.fraction * geometry.height(ofRow: row) - metrics.topInset
        scroll(scrollA, to: NSPoint(x: x ?? anchor.x, y: y))
        mirror(from: scrollA, to: scrollB)
    }

    // MARK: selection of changes and navigation

    func selectChange(_ index: Int?, scroll: Bool) {
        guard let model else { return }
        let index = index.flatMap { (0 ..< model.changeCount).contains($0) ? $0 : nil }
        let previous = selectedChange
        selectedChange = index
        if previous != index {
            for change in [previous, index].compactMap({ $0 }) {
                invalidate(change: change)
            }
        }
        if scroll, let index { reveal(change: index) }
        onSelectionChange?(index)
    }

    /// Centres change `index` vertically: in each pane on its own side in
    /// Fluid, in the shared geometry otherwise.
    private func reveal(change index: Int) {
        guard let geometryA, let geometryB else { return }
        func centre(_ geometry: PaneGeometry, _ view: NSScrollView) -> CGFloat {
            let rows = geometry.rows.rows(ofChange: index)
            let top = geometry.y(ofRow: rows.lowerBound), bottom = geometry.y(ofRow: rows.upperBound)
            return (top + bottom) / 2 - view.contentView.bounds.height / 2
        }
        if mode == .fluid {
            syncing = true
            scroll(scrollA, to: NSPoint(x: 0, y: centre(geometryA, scrollA)))
            scroll(scrollB, to: NSPoint(x: 0, y: centre(geometryB, scrollB)))
            syncing = false
        } else {
            scroll(toY: centre(geometryA, scrollA))
        }
    }

    func selectNextChange() {
        guard let count = model?.changeCount, count > 0 else { return }
        selectChange(selectedChange.map { ($0 + 1) % count } ?? 0, scroll: true)
    }

    func selectPreviousChange() {
        guard let count = model?.changeCount, count > 0 else { return }
        selectChange(selectedChange.map { ($0 + count - 1) % count } ?? count - 1, scroll: true)
    }

    /// Selects the change under a row of a pane, if any (clicks).
    func selectChange(atRow row: Int, pane: DiffSide = .a) {
        guard let change = geometry(for: pane)?.rows.change(atRow: row) else { return }
        selectChange(change, scroll: false)
    }

    private func invalidate(change: Int) {
        for (pane, geometry) in [(paneA, geometryA), (paneB, geometryB)] {
            guard let geometry else { continue }
            let rows = geometry.rows.rows(ofChange: change)
            let top = geometry.y(ofRow: rows.lowerBound) - 1
            let height = geometry.y(ofRow: rows.upperBound) - top + 2
            pane.setNeedsDisplay(NSRect(x: 0, y: top, width: pane.bounds.width, height: height))
        }
        gutterA.needsDisplay = true
        gutterB.needsDisplay = true
        divider.needsDisplay = true
    }

    /// True when block `index` is the selected change.
    func isSelected(block index: Int) -> Bool {
        guard let selectedChange, let model, selectedChange < model.changeCount else { return false }
        return model.layout.changes[selectedChange] == index
    }

    // MARK: text selection

    /// Sets the text selection (nil clears it) and redraws.
    func setSelection(_ new: TextSelection?) {
        guard new != selection else { return }
        selection = new
        paneA.needsDisplay = true
        paneB.needsDisplay = true
        gutterA.needsDisplay = true
        gutterB.needsDisplay = true
        textPane(new?.pane ?? .a).caretMoved()
    }

    /// Moves the caret `delta` lines up or down in its pane, skipping
    /// padding, and scrolls it into view (the arrow keys).
    func moveCaret(by delta: Int, extending: Bool = false) {
        guard let current = selection, let geometry = geometry(for: current.pane) else { return }
        var row = current.head.row
        repeat {
            row += delta > 0 ? 1 : -1
        } while row > 0 && row < geometry.rows.count - 1 && lineText(pane: current.pane, row: row) == nil
        row = max(0, min(row, geometry.rows.count - 1))
        var offset = 0
        if let text = lineText(pane: current.pane, row: row).map({ $0 as NSString }) {
            offset = min(current.head.offset, text.length)
            // Never inside a character (a surrogate pair or a cluster).
            if offset > 0, offset < text.length { offset = text.rangeOfComposedCharacterSequence(at: offset).location }
        }
        let head = TextPosition(row: row, offset: offset)
        setSelection(TextSelection(pane: current.pane, anchor: extending ? current.anchor : head, head: head))
        revealSelection()
        if let change = geometry.rows.change(atRow: row), change != selectedChange { selectChange(change, scroll: false) }
    }

    /// The pane that has (or last had) the text selection.
    var selectionPane: DiffSide { selection?.pane ?? .a }

    /// Text of the line shown on `row` of a pane, if it shows a line.
    func lineText(pane: DiffSide, row: Int) -> String? {
        guard let model, let geometry = geometry(for: pane),
              case let .line(side, line, _) = geometry.rows.content(row) else { return nil }
        return model.side(side).text(ofLine: line)
    }

    /// The selected text, lines joined with newlines; padding rows are
    /// skipped.
    ///
    /// Rule: each line contributes its selected characters, followed by
    /// its own line terminator ("\n") when the selection continues past
    /// its end into a later row. Padding and the trailer row contribute
    /// nothing. So a whole line (triple click) copies as "text\n", and
    /// Select All copies the file's lines as they are.
    func selectedText() -> String? {
        guard let selection, !selection.isEmpty, let model, let geometry = geometry(for: selection.pane)
        else { return nil }
        let lower = selection.lower, upper = selection.upper
        var result = ""
        var row = lower.row
        while row <= upper.row, row < geometry.rows.count {
            if case let .line(side, line, _) = geometry.rows.content(row) {
                let text = model.side(side).text(ofLine: line) as NSString
                let length = text.length
                var from = row == lower.row ? min(lower.offset, length) : 0
                var to = row == upper.row ? min(upper.offset, length) : length
                // Whole characters only, even if an offset fell inside one.
                if from > 0, from < length { from = text.rangeOfComposedCharacterSequence(at: from).location }
                if to > 0, to < length {
                    let range = text.rangeOfComposedCharacterSequence(at: to)
                    if range.location != to { to = range.location + range.length }
                }
                if from < to { result += text.substring(with: NSRange(location: from, length: to - from)) }
                if row < upper.row, model.side(side).hasTerminator(line) { result += "\n" }
            }
            row += 1
        }
        return result
    }

    /// Selects everything in the pane that has the selection.
    func selectAllText() {
        guard let geometry = geometry(for: selectionPane) else { return }
        let last = max(0, geometry.rows.count - 1)
        let end = lineText(pane: selectionPane, row: last)?.utf16.count ?? 0
        setSelection(TextSelection(pane: selectionPane, anchor: TextPosition(row: 0, offset: 0),
                                   head: TextPosition(row: last, offset: end)))
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText() else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    @objc override func selectAll(_ sender: Any?) {
        selectAllText()
    }

    /// Scrolls the selection into view (Jump to Selection).
    func revealSelection() {
        guard let selection, let geometry = geometry(for: selection.pane) else { return }
        let view = scrollView(for: selection.pane)
        let y = geometry.y(ofRow: selection.head.row)
        let visible = view.contentView.bounds
        if y < visible.minY || y + geometry.lineHeight > visible.maxY {
            scroll(view, to: NSPoint(x: visible.minX, y: y - visible.height / 2))
            mirror(from: view, to: view === scrollA ? scrollB : scrollA)
        }
    }

    // MARK: find

    /// Scrolls `match` into view, centred, in the pane that shows its side.
    func reveal(_ match: FindMatch) {
        let pane: DiffSide = mode == .unified ? .a : match.side
        guard let geometry = geometry(for: pane), let shaper = shaper(for: match.side),
              let row = geometry.rows.row(ofLine: match.line, side: match.side) else { return }
        let view = scrollView(for: pane)
        let visible = view.contentView.bounds
        let shaped = shaper.line(match.line)
        var x = shaper.x(ofOffset: match.range.lowerBound, in: shaped, line: match.line)
        var segment = 0
        if wrapsLines {
            let width = CGFloat(pane == .a ? wrapColumns.a : wrapColumns.b) * metrics.charWidth
            if width > 0 {
                let count = wrappedHeight(side: match.side, line: match.line)
                segment = min(Int(x / width), count - 1)
                if let slice = wrapSlice(segment, side: match.side, line: match.line, pane: pane),
                   x < slice.lowerBound, segment > 0 {
                    segment -= 1
                }
                x -= wrapSlice(segment, side: match.side, line: match.line, pane: pane)?.lowerBound ?? 0
            }
        }
        let y = geometry.y(ofRow: row) + CGFloat(segment) * geometry.lineHeight
        var target = visible.origin
        target.y = y + geometry.lineHeight / 2 - visible.height / 2
        let left = x + metrics.textInset
        if left < visible.minX + 20 || left > visible.maxX - 40 { target.x = max(0, left - visible.width / 3) }
        scroll(view, to: target)
        mirror(from: view, to: view === scrollA ? scrollB : scrollA)
    }

    // MARK: first paint

    func paneDidDraw(_ side: DiffSide) {
        guard model != nil, !firstPaintReported else { return }
        paintedSides.insert(side == .a ? 0 : 1)
        if paintedSides.count == 2 || mode == .unified {
            firstPaintReported = true
            onFirstPaint?()
        }
    }

    /// Largest on-screen vertical offset between an unchanged line in A and
    /// its counterpart in B, over the visible rows (0 when aligned). Only
    /// Blocks promises alignment; the other layouts report 0.
    func visibleAlignmentError() -> CGFloat {
        guard mode == .blocks, let model, let geometryA, let geometryB else { return 0 }
        let yA = scrollA.contentView.bounds.minY, yB = scrollB.contentView.bounds.minY
        var worst: CGFloat = 0
        for row in geometryA.rows(in: yA, yA + scrollA.contentView.bounds.height) {
            guard case let .line(_, lineA, block) = geometryA.rows.content(row),
                  model.layout.blocks[block].isShownOnce else { continue }
            let range = model.layout.blocks[block]
            let lineB = range.b.lowerBound + (lineA - range.a.lowerBound)
            guard let rowB = geometryB.rows.row(ofLine: lineB, side: .b) else { continue }
            let onScreenA = geometryA.y(ofRow: row) - yA, onScreenB = geometryB.y(ofRow: rowB) - yB
            worst = max(worst, abs(onScreenA - onScreenB))
        }
        return worst
    }

    // MARK: overview

    /// Marks in the scroller track: a dot per change, a tick per find match.
    private func updateOverview() {
        let pane: DiffSide = mode == .unified ? .a : .b
        let scroller = pane == .a ? overviewA : overviewB
        (pane == .a ? overviewB : overviewA).marks = []
        guard let model, let geometry = geometry(for: pane) else {
            scroller.marks = []
            return
        }
        let height = max(geometry.documentHeight, 1)
        var marks: [OverviewScroller.Mark] = []
        marks.reserveCapacity(model.changeCount)
        for (index, block) in model.layout.changes.enumerated() where model.layout.blocks[block].kind != .equal {
            let rows = geometry.rows.rows(ofChange: index)
            let top = geometry.y(ofRow: rows.lowerBound), bottom = geometry.y(ofRow: rows.upperBound)
            let kind: OverviewScroller.Mark.Kind = model.layout.blocks[block].isInsert ? .insert
                : model.layout.blocks[block].isDelete ? .delete : .change
            marks.append(.init(top: top / height, bottom: bottom / height, kind: kind))
        }
        // One tick per pixel row of the track, however many matches.
        let rows = max(Int(scroller.bounds.height), 200)
        var ticks = Set<Int>()
        for (side, lines) in findHighlights.lines {
            for line in lines.keys {
                // Blocks shows A matches against the shared rows too.
                let row = mode == .blocks ? model.layout.row(ofLine: line, side: side)
                                          : geometry.rows.row(ofLine: line, side: side)
                guard let row else { continue }
                ticks.insert(Int(geometry.y(ofRow: row) / height * CGFloat(rows)))
            }
        }
        for tick in ticks.sorted() {
            let top = CGFloat(tick) / CGFloat(rows)
            marks.append(.init(top: top, bottom: top + 1 / CGFloat(rows), kind: .match))
        }
        scroller.marks = marks
    }
}

/// Wrapped heights of rows, from the visual lines every line needs.
struct WrapHeights {
    /// Visual lines of line `line` of a side.
    let height: (DiffSide, Int) -> Int

    /// Visual lines of a line `columns` wide wrapped at `width` columns.
    static func lines(_ columns: Int, _ width: Int) -> Int {
        width <= 0 || columns <= width ? 1 : (columns + width - 1) / width
    }

    /// Visual lines of a line `width` points wide wrapped at `wrap` points.
    static func lines(width: CGFloat, wrap: CGFloat) -> Int {
        wrap <= 0 || width <= wrap + 0.5 ? 1 : Int(ceil((width - 0.5) / wrap))
    }

    /// From columns only (all lines monospaced ASCII).
    init(a: [Int32], b: [Int32], columnsA: Int, columnsB: Int) {
        height = { side, line in
            side == .a ? Self.lines(Int(a[line]), columnsA) : Self.lines(Int(b[line]), columnsB)
        }
    }

    init(height: @escaping (DiffSide, Int) -> Int) {
        self.height = height
    }

    /// Blocks: each row as tall as the taller of its two sides, so a line
    /// and its counterpart (or its padding) always share a row height.
    func blocks(_ layout: BlocksLayout) -> RowHeights {
        var heights = [Int]()
        heights.reserveCapacity(layout.rowCount)
        for block in layout.blocks {
            let count = max(block.a.count, block.b.count)
            for offset in 0 ..< count {
                let hA = offset < block.a.count ? height(.a, block.a.lowerBound + offset) : 1
                let hB = offset < block.b.count ? height(.b, block.b.lowerBound + offset) : 1
                heights.append(max(hA, hB))
            }
        }
        heights.append(1)
        return RowHeights(heights)
    }

    /// Fluid: every line of one side as tall as it needs.
    func fluid(_ side: DiffSide, count: Int) -> RowHeights {
        RowHeights((0 ..< count).map { height(side, $0) } + [1])
    }

    /// Unified: unchanged lines (shown as their A line), then each change
    /// as its A lines and its B lines.
    func unified(_ layout: BlocksLayout) -> RowHeights {
        var heights = [Int]()
        for block in layout.blocks {
            for line in block.a { heights.append(height(.a, line)) }
            if !block.isShownOnce {
                for line in block.b { heights.append(height(.b, line)) }
            }
        }
        heights.append(1)
        return RowHeights(heights)
    }
}

/// A subview of `BlocksDiffView` that reads its state.
@MainActor
protocol BlocksPart: AnyObject {
    var host: BlocksDiffView? { get set }
}

/// Copy needs selected text.
extension BlocksDiffView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): selectedText()?.isEmpty == false
        case #selector(selectAll(_:)): model != nil
        default: true
        }
    }
}
