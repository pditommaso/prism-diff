// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import CoreText
import DiffCore
import os

/// Signposts around drawing, for Instruments and the scroll bench.
enum DrawSignposts {
    static let signposter = OSSignposter(subsystem: "io.github.pditommaso.prism", category: "draw")
}

/// One pane of text, drawn with CoreText. Only the rows that intersect the
/// dirty rect are drawn, and of a long line only the chunks that intersect
/// it (see `LineShaper`). With wrapping, a line's visual lines are slices
/// of the same unwrapped line, shifted left and clipped.
///
/// In Unified the A pane shows lines of both sides.
@MainActor
final class PaneTextView: NSView, BlocksPart {
    /// Which pane this is (A is the only one in Unified).
    let side: DiffSide
    weak var host: BlocksDiffView?
    private var lineElements: [Int: LineAccessibilityElement] = [:]
    private var dragGranularity = 1

    init(side: DiffSide) {
        self.side = side
        super.init(frame: .zero)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(side == .a ? "A text" : "B text")
        setAccessibilityIdentifier(side == .a ? "prism.pane.a" : "prism.pane.b")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: drawing

    /// Width of one visual line when wrapping (nil when not wrapping).
    private func wrapWidth(_ host: BlocksDiffView) -> CGFloat? {
        guard host.wrapsLines else { return nil }
        let columns = side == .a ? host.wrapColumns.a : host.wrapColumns.b
        return columns > 0 ? CGFloat(columns) * host.metrics.charWidth : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let state = DrawSignposts.signposter.beginInterval("pane")
        defer { DrawSignposts.signposter.endInterval("pane", state) }
        guard let host, let context = NSGraphicsContext.current?.cgContext else { return }
        let palette = host.palette
        context.setFillColor(palette.background)
        context.fill(dirtyRect)
        guard let model = host.model, let geometry = host.geometry(for: side) else { return }
        let layout = model.layout
        let x0 = dirtyRect.minX, width = dirtyRect.width
        let dims = host.findHighlights.dims
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let visibleRows = geometry.rows(in: dirtyRect.minY, dirtyRect.maxY)

        if dims {
            // Veil what lies outside the rows: the margins and the trailer.
            context.setFillColor(palette.findDim)
            let top = geometry.y(ofRow: 0), bottom = geometry.y(ofRow: geometry.rows.trailerRow)
            if dirtyRect.minY < top {
                context.fill(CGRect(x: x0, y: dirtyRect.minY, width: width, height: top - dirtyRect.minY))
            }
            if dirtyRect.maxY > bottom {
                context.fill(CGRect(x: x0, y: bottom, width: width, height: dirtyRect.maxY - bottom))
            }
        }

        for row in visibleRows {
            let top = geometry.y(ofRow: row), rowHeight = geometry.height(ofRow: row)
            let rowRect = CGRect(x: x0, y: top, width: width, height: rowHeight)
            switch geometry.rows.content(row) {
            case let .line(lineSide, line, block):
                drawLine(context, host: host, model: model, geometry: geometry, row: row, rowRect: rowRect,
                         side: lineSide, line: line, block: block, dirtyRect: dirtyRect)
            case let .spacer(block, isTop, isBottom):
                drawSpacer(context, block: layout.blocks[block], palette: palette, rect: rowRect,
                           top: isTop, bottom: isBottom)
                if dims {
                    context.setFillColor(palette.findDim)
                    context.fill(rowRect)
                }
            case .trailer:
                break
            }
        }
        if host.mode == .fluid { drawInsertionMarkers(context, host: host, geometry: geometry, rows: visibleRows) }
        host.paneDidDraw(side)
    }

    private func drawLine(_ context: CGContext, host: BlocksDiffView, model: ComparisonModel,
                          geometry: PaneGeometry, row: Int, rowRect: CGRect,
                          side lineSide: DiffSide, line: Int, block: Int, dirtyRect: CGRect) {
        guard let shaper = host.shaper(for: lineSide) else { return }
        let palette = host.palette, metrics = host.metrics
        let layout = model.layout
        let text = model.side(lineSide)
        let range = layout.blocks[block]
        let colors = palette.colors(for: range)
        let selected = colors != nil && host.isSelected(block: block)
        let lineHeight = metrics.lineHeight, inset = metrics.textInset
        let top = rowRect.minY

        if let colors {
            context.setFillColor(selected ? colors.selectedBand : colors.band)
            context.fill(rowRect)
            if host.mode == .unified {
                // Outline of the change's box and the line between its A
                // and B halves.
                context.setFillColor(selected ? colors.selectedGutter : colors.border)
                let rows = geometry.rows.rows(ofBlock: block)
                if row == rows.lowerBound {
                    context.fill(CGRect(x: rowRect.minX, y: top, width: rowRect.width, height: 1))
                }
                if row == rows.upperBound - 1 {
                    context.fill(CGRect(x: rowRect.minX, y: rowRect.maxY - 1, width: rowRect.width, height: 1))
                }
                if lineSide == .b, line == range.b.lowerBound, !range.a.isEmpty {
                    context.setAlpha(0.45)
                    context.fill(CGRect(x: rowRect.minX, y: top, width: rowRect.width, height: 1))
                    context.setAlpha(1)
                }
            }
        }

        let shaped = shaper.line(line)
        let wrap = wrapWidth(host)
        let segments = wrap == nil ? 1 : host.wrappedHeight(side: lineSide, line: line)
        let charWidth = metrics.charWidth

        /// Unwrapped x range drawn by segment `k`, and its x shift: a whole
        /// number of characters per wrapped visual line.
        var slices: [Int: Range<CGFloat>] = [:]
        func window(_ k: Int) -> (visible: Range<CGFloat>, shift: CGFloat) {
            if let wrap {
                let slice = slices[k] ?? host.wrapSlice(k, side: lineSide, line: line, pane: side)
                    ?? (CGFloat(k) * wrap ..< CGFloat(k + 1) * wrap)
                slices[k] = slice
                // The last slice runs to the end of the line; a non-ASCII
                // slice may pass the wrap width by up to one character.
                let end = min(slice.upperBound, slice.lowerBound + wrap + charWidth * 3)
                return (slice.lowerBound ..< end, slice.lowerBound)
            }
            return ((dirtyRect.minX - inset) ..< (dirtyRect.maxX - inset), 0)
        }
        /// True when UTF-16 range `lower ..< upper` may overlap `visible`
        /// (cheap: by whole chunks, without shaping anything).
        func overlaps(_ lower: Int, _ upper: Int, _ visible: Range<CGFloat>) -> Bool {
            let rough = shaper.roughRange(lower, upper, in: shaped, line: line)
            return rough.lowerBound <= visible.upperBound + charWidth * 8
                && rough.upperBound >= visible.lowerBound - charWidth * 8
        }
        /// Fills the part of unwrapped `[from, to)` that segment `k` shows.
        func fill(_ from: CGFloat, _ to: CGFloat, k: Int, segTop: CGFloat, inflate: CGFloat = 0,
                  radius: CGFloat = 0, stroke: CGColor? = nil) {
            let (visible, shift) = window(k)
            let low = max(from, visible.lowerBound - 2), high = min(to, visible.upperBound + 2)
            guard high > low || (from == to && from >= visible.lowerBound && from < visible.upperBound) else { return }
            let rect = CGRect(x: inset + low - shift, y: segTop, width: max(high - low, 1), height: lineHeight)
                .insetBy(dx: -inflate, dy: inflate > 0 ? 1 : 0)
            if radius > 0 {
                let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                context.addPath(path)
                context.fillPath()
                if let stroke {
                    context.setStrokeColor(stroke)
                    context.setLineWidth(1)
                    context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius,
                                           cornerHeight: radius, transform: nil))
                    context.strokePath()
                }
            } else {
                context.fill(rect)
            }
        }

        let segmentRange = 0 ..< segments
        func segmentTop(_ k: Int) -> CGFloat { top + CGFloat(k) * lineHeight }
        func onScreen(_ k: Int) -> Bool {
            let y = segmentTop(k)
            return y < dirtyRect.maxY && y + lineHeight > dirtyRect.minY
        }

        // Word differences.
        if let colors, !shaped.words.isEmpty {
            for k in segmentRange where onScreen(k) {
                let (visible, _) = window(k)
                for word in shaped.words where overlaps(word.lowerBound, word.upperBound, visible) {
                    let start = shaper.x(ofOffset: word.lowerBound, in: shaped, line: line)
                    if word.isEmpty {
                        // Insertion point: text exists only on the other side.
                        context.setFillColor(colors.border)
                        fill(start - 0.5, start + 0.5, k: k, segTop: segmentTop(k) + 1)
                    } else {
                        let end = shaper.x(ofOffset: word.upperBound, in: shaped, line: line)
                        context.setFillColor(selected ? colors.selectedWord : colors.word)
                        fill(start, end, k: k, segTop: segmentTop(k))
                    }
                }
            }
        }

        let highlights = host.findHighlights
        if highlights.dims {
            context.setFillColor(palette.findDim)
            context.fill(rowRect)
        }

        // Selection.
        if let selection = host.selection, selection.pane == side, !selection.isEmpty,
           row >= selection.lower.row, row <= selection.upper.row {
            let from = row == selection.lower.row
                ? shaper.x(ofOffset: min(selection.lower.offset, shaped.utf16Count), in: shaped, line: line) : 0
            let to = row == selection.upper.row
                ? shaper.x(ofOffset: min(selection.upper.offset, shaped.utf16Count), in: shaped, line: line)
                : shaper.width(of: shaped, line: line) + charWidth
            context.setFillColor(palette.selection)
            for k in segmentRange where onScreen(k) { fill(from, to, k: k, segTop: segmentTop(k)) }
        }

        // Find matches; the current one as a pill.
        if let matches = highlights.lines[lineSide]?[line] {
            for match in matches {
                let current = highlights.current.map { $0.side == lineSide && $0.line == line && $0.range == match }
                    ?? false
                for k in segmentRange where onScreen(k) && overlaps(match.lowerBound, match.upperBound, window(k).visible) {
                    let start = shaper.x(ofOffset: match.lowerBound, in: shaped, line: line)
                    let end = shaper.x(ofOffset: match.upperBound, in: shaped, line: line)
                    context.setFillColor(current ? palette.findCurrent : palette.findMatch)
                    fill(start, end, k: k, segTop: segmentTop(k), inflate: current ? 3 : 1,
                         radius: current ? lineHeight / 2 - 1 : 3,
                         stroke: current ? nil : palette.findMatchBorder)
                }
            }
        }

        // Text, then the line-end mark of changed lines.
        let endMarkX: CGFloat? = colors != nil && text.hasTerminator(line)
            ? shaper.width(of: shaped, line: line) + 2 : nil
        let textColor = colors == nil || (host.mode == .unified && range.kind == .equal) ? palette.equalText : palette.text
        for k in segmentRange where onScreen(k) {
            let (visible, shift) = window(k)
            let segTop = segmentTop(k)
            if wrap != nil {
                context.saveGState()
                // The slice only: not the end of the previous one, nor the
                // start of the next.
                context.clip(to: CGRect(x: inset - 0.5, y: segTop, width: visible.upperBound - visible.lowerBound + 1,
                                        height: lineHeight))
            }
            context.setFillColor(textColor)
            shaper.draw(shaped, line: line, in: context, origin: CGPoint(x: inset - shift, y: segTop + metrics.baseline),
                        visible: visible)
            if let endMarkX, endMarkX >= visible.lowerBound, endMarkX < visible.upperBound
                || (wrap == nil && endMarkX < visible.upperBound + charWidth) {
                context.setFillColor(palette.invisible)
                context.textPosition = CGPoint(x: inset + endMarkX - shift, y: segTop + metrics.baseline)
                CTLineDraw(shaper.endMark, context)
            }
            if wrap != nil { context.restoreGState() }
        }
    }

    /// Fluid: a horizontal line where a change has no lines on this side.
    private func drawInsertionMarkers(_ context: CGContext, host: BlocksDiffView, geometry: PaneGeometry,
                                      rows: Range<Int>) {
        guard let model = host.model, !rows.isEmpty else { return }
        let layout = model.layout
        let last = layout.blocks.count - 1
        let first = geometry.rows.block(atRow: rows.lowerBound) ?? last
        let end = geometry.rows.block(atRow: rows.upperBound - 1) ?? last
        guard first >= 0 else { return }
        for index in max(0, first - 1) ... min(last, end + 1) {
            let block = layout.blocks[index]
            let own = side == .a ? block.a : block.b
            guard own.isEmpty, let colors = host.palette.colors(for: block) else { continue }
            let y = geometry.y(ofRow: own.lowerBound)
            context.setFillColor(host.isSelected(block: index) ? colors.selectedGutter : colors.border)
            context.fill(CGRect(x: bounds.minX, y: y - 0.5, width: bounds.width, height: 1))
        }
    }

    // MARK: hit testing and the mouse

    /// The text position under `point` (in this view's coordinates).
    func position(at point: NSPoint) -> TextPosition? {
        guard let host, let model = host.model, let geometry = host.geometry(for: side) else { return nil }
        let count = geometry.rows.count
        if point.y < geometry.y(ofRow: 0) { return TextPosition(row: 0, offset: 0) }
        let row = geometry.row(atY: point.y)
        if row >= count {
            let last = count - 1
            return TextPosition(row: last, offset: host.lineText(pane: side, row: last)?.utf16.count ?? 0)
        }
        guard case let .line(lineSide, line, _) = geometry.rows.content(max(row, 0)),
              let shaper = host.shaper(for: lineSide) else { return TextPosition(row: max(row, 0), offset: 0) }
        _ = model
        let shaped = shaper.line(line)
        var x = point.x - host.metrics.textInset
        if wrapWidth(host) != nil {
            let segments = host.wrappedHeight(side: lineSide, line: line)
            let k = max(0, min(segments - 1, Int((point.y - geometry.y(ofRow: row)) / geometry.lineHeight)))
            if let slice = host.wrapSlice(k, side: lineSide, line: line, pane: side) {
                x = min(max(x + slice.lowerBound, slice.lowerBound), slice.upperBound)
            }
        }
        return TextPosition(row: row, offset: shaper.offset(atX: x, in: shaped, line: line))
    }

    /// Word (double click) or line (triple click) around `position`.
    private func unit(around position: TextPosition, granularity: Int) -> (TextPosition, TextPosition) {
        guard let host, let text = host.lineText(pane: side, row: position.row) else { return (position, position) }
        if granularity >= 3 {
            // The whole line with its terminator: up to the start of the
            // next row (padding and the trailer row add nothing to a copy).
            let rows = host.geometry(for: side)?.rows.count ?? 0
            let next = TextPosition(row: position.row + 1, offset: 0)
            return (TextPosition(row: position.row, offset: 0),
                    next.row < rows ? next : TextPosition(row: position.row, offset: text.utf16.count))
        }
        let string = NSAttributedString(string: text)
        let offset = min(position.offset, max(text.utf16.count - 1, 0))
        let range = text.isEmpty ? NSRange(location: 0, length: 0) : string.doubleClick(at: offset)
        return (TextPosition(row: position.row, offset: range.location),
                TextPosition(row: position.row, offset: range.location + range.length))
    }

    override func mouseDown(with event: NSEvent) {
        guard let host else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let position = position(at: point) else { return }
        host.selectChange(atRow: position.row, pane: side)
        dragGranularity = min(event.clickCount, 3)
        if event.modifierFlags.contains(.shift), let current = host.selection, current.pane == side {
            host.setSelection(TextSelection(pane: side, anchor: current.anchor, head: position))
        } else if dragGranularity >= 2 {
            let (start, end) = unit(around: position, granularity: dragGranularity)
            host.setSelection(TextSelection(pane: side, anchor: start, head: end))
            // A double click edits the block, with the word selected.
            if dragGranularity == 2, let begin = host.onBeginEditing,
               begin(side, TextSelection(pane: side, anchor: start, head: end), nil) {
                return
            }
        } else {
            host.setSelection(TextSelection(pane: side, anchor: position, head: position))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let host, let current = host.selection, current.pane == side else { return }
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let position = position(at: point) else { return }
        if dragGranularity >= 2 {
            let (start, end) = unit(around: position, granularity: dragGranularity)
            let (anchorStart, anchorEnd) = unit(around: current.anchor, granularity: dragGranularity)
            if position < current.anchor {
                host.setSelection(TextSelection(pane: side, anchor: max(anchorEnd, current.anchor), head: start))
            } else {
                host.setSelection(TextSelection(pane: side, anchor: min(anchorStart, current.anchor), head: end))
            }
        } else {
            host.setSelection(TextSelection(pane: side, anchor: current.anchor, head: position))
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        switch event.keyCode {
        case 53: // Escape
            NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: self)
            return
        case 125 where modifiers.isEmpty: // Down
            host?.moveCaret(by: 1, extending: event.modifierFlags.contains(.shift))
            return
        case 126 where modifiers.isEmpty: // Up
            host?.moveCaret(by: -1, extending: event.modifierFlags.contains(.shift))
            return
        default:
            break
        }
        // Typing starts editing the block under the caret.
        if Self.isTyping(event), let host, let begin = host.onBeginEditing, let selection = host.selection,
           selection.pane == side, begin(side, selection, event) {
            return
        }
        super.keyDown(with: event)
    }

    /// True for a key press that enters or deletes text: printable
    /// characters, Return, Tab and Delete, without Command or Control.
    static func isTyping(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .control]).isEmpty,
              let characters = event.characters, let scalar = characters.unicodeScalars.first else { return false }
        // Arrows, function keys, Home, End and the like use private-use
        // code points.
        if (0xF700 ... 0xF8FF).contains(scalar.value) { return false }
        if scalar.value == 0x1B { return false }
        return true
    }

    // MARK: accessibility

    /// Forgets the line elements (the rows changed).
    func invalidateAccessibility() {
        lineElements.removeAll()
    }

    /// The element for `row`, made on demand and kept while the rows stay
    /// the same, so assistive apps see stable objects.
    func lineElement(row: Int) -> LineAccessibilityElement? {
        guard let host, let geometry = host.geometry(for: side), row >= 0, row < geometry.rows.count,
              case .line = geometry.rows.content(row) else { return nil }
        if let element = lineElements[row] { return refresh(element) }
        if lineElements.count > 512 { lineElements.removeAll() }
        let element = LineAccessibilityElement(row: row)
        element.setAccessibilityParent(self)
        element.setAccessibilityRole(.staticText)
        lineElements[row] = element
        return refresh(element)
    }

    /// Brings an element's label, value, frame and focus up to date.
    @discardableResult
    func refresh(_ element: LineAccessibilityElement) -> LineAccessibilityElement {
        guard let host, let model = host.model, let geometry = host.geometry(for: side),
              element.row < geometry.rows.count,
              case let .line(lineSide, line, _) = geometry.rows.content(element.row) else { return element }
        element.setAccessibilityLabel("\(lineSide == .a ? "A" : "B") line \(line + 1)")
        let text = model.side(lineSide).text(ofLine: line)
        element.setAccessibilityValue(text.utf16.count > 4096 ? String(text.prefix(4096)) : text)
        if let window {
            let rect = NSRect(x: visibleRect.minX, y: geometry.y(ofRow: element.row),
                              width: visibleRect.width, height: geometry.height(ofRow: element.row))
            element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
        }
        let focused = host.selection.map { $0.pane == side && $0.head.row == element.row } ?? false
        element.setAccessibilityFocused(focused)
        return element
    }

    /// Rows shown in the pane's clip view.
    private func visibleRows() -> Range<Int> {
        guard let host, let geometry = host.geometry(for: side) else { return 0 ..< 0 }
        let visible = visibleRect
        return geometry.rows(in: visible.minY, visible.maxY)
    }

    override func accessibilityChildren() -> [Any]? {
        visibleRows().compactMap { lineElement(row: $0) }
    }

    /// The current line's element. AppKit asks on the main thread, but the
    /// SDK declares the property nonisolated.
    override var accessibilityFocusedUIElement: Any? {
        let pane = self
        nonisolated(unsafe) var focused: Any?
        MainActor.assumeIsolated {
            focused = pane.focusedLineElement() ?? pane
        }
        return focused
    }

    private func focusedLineElement() -> LineAccessibilityElement? {
        guard let host, let selection = host.selection, selection.pane == side else { return nil }
        return lineElement(row: selection.head.row)
    }

    /// Tells assistive apps that the current line changed.
    func caretMoved() {
        guard let host, let selection = host.selection, selection.pane == side,
              let element = lineElement(row: selection.head.row) else { return }
        NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
    }
}

/// One visible line of a pane, for VoiceOver: its number as the label and
/// its text as the value. The pane fills in its attributes whenever it
/// hands the element out (see `PaneTextView.refresh(_:)`).
final class LineAccessibilityElement: NSAccessibilityElement {
    let row: Int

    init(row: Int) {
        self.row = row
        super.init()
    }
}

/// Fills one row of Blocks padding and draws the outline edges it carries.
@MainActor
func drawSpacer(_ context: CGContext, block: DiffBlock, palette: ThemePalette, rect: CGRect, top: Bool, bottom: Bool) {
    context.setFillColor(palette.spacer)
    context.fill(rect)
    guard let colors = palette.colors(for: block) else { return }
    context.setFillColor(colors.border)
    if top { context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1)) }
    if bottom { context.fill(CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1)) }
}
