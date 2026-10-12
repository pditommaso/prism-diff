// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import CoreText
import DiffCore

/// Line numbers of one pane. It does not scroll itself: it draws the rows
/// that are visible in its pane, at the pane's vertical offset. In Unified
/// it has two columns, A numbers and B numbers, and marks changed lines
/// with their side's letter. The current line's number is bold.
@MainActor
final class GutterView: NSView, BlocksPart {
    let side: DiffSide
    weak var host: BlocksDiffView?
    private var cache: [Int: CTLine] = [:]
    private var boldCache: [Int: CTLine] = [:]
    private var letters: [DiffSide: CTLine] = [:]

    init(side: DiffSide) {
        self.side = side
        super.init(frame: .zero)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    func resetCache() {
        cache.removeAll(keepingCapacity: true)
        boldCache.removeAll(keepingCapacity: true)
        letters.removeAll()
    }

    private func make(_ string: String, font: NSFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
    }

    private func number(_ value: Int, bold: Bool, metrics: TextMetrics) -> CTLine {
        if let cached = bold ? boldCache[value] : cache[value] { return cached }
        if cache.count > 2048 { cache.removeAll(keepingCapacity: true) }
        if boldCache.count > 64 { boldCache.removeAll(keepingCapacity: true) }
        let font = bold ? NSFont.monospacedDigitSystemFont(ofSize: metrics.numberFont.pointSize, weight: .bold)
                        : metrics.numberFont
        let line = make(String(value), font: font)
        if bold { boldCache[value] = line } else { cache[value] = line }
        return line
    }

    private func letter(_ side: DiffSide, metrics: TextMetrics) -> CTLine {
        if let cached = letters[side] { return cached }
        let line = make(side == .a ? "A" : "B",
                        font: .systemFont(ofSize: max(metrics.numberFont.pointSize - 2, 6), weight: .medium))
        letters[side] = line
        return line
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let host, let context = NSGraphicsContext.current?.cgContext else { return }
        let palette = host.palette
        context.setFillColor(palette.gutterBackground)
        context.fill(dirtyRect)
        let width = bounds.width
        guard let model = host.model, let geometry = host.geometry(for: side) else { return }
        let metrics = host.metrics
        let offset = host.scrollY(of: side)
        let layout = model.layout
        let unified = host.mode == .unified
        let caretRow = host.selection.flatMap { $0.pane == side ? $0.head.row : nil }
        let columnWidth = unified ? floor(width / 2) : width
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        for row in geometry.rows(in: dirtyRect.minY + offset, dirtyRect.maxY + offset) {
            let top = geometry.y(ofRow: row) - offset
            let rowHeight = geometry.height(ofRow: row)
            let cell = CGRect(x: 0, y: top, width: width - 1, height: rowHeight)
            var numberColor = palette.lineNumber
            var letterSide: DiffSide?
            var blockIndex: Int?
            switch geometry.rows.content(row) {
            case let .line(lineSide, _, block):
                blockIndex = block
                if let colors = palette.colors(for: layout.blocks[block]) {
                    let selected = host.isSelected(block: block)
                    context.setFillColor(selected ? colors.selectedGutter : colors.gutter)
                    context.fill(cell)
                    if selected { numberColor = colors.selectedNumber }
                    if unified { letterSide = lineSide }
                } else if layout.resolved.contains(block), host.isSelected(block: block) {
                    // A resolved change keeps its selected number cells.
                    context.setFillColor(palette.change.selectedGutter)
                    context.fill(cell)
                    numberColor = palette.change.selectedNumber
                }
            case let .spacer(block, isTop, isBottom):
                drawSpacer(context, block: layout.blocks[block], palette: palette,
                           rect: CGRect(x: 0, y: top, width: width, height: rowHeight), top: isTop, bottom: isBottom)
                if side == .a, let colors = palette.colors(for: layout.blocks[block]) {
                    // Left edge of the box; the divider draws the other edge.
                    context.setFillColor(colors.border)
                    context.fill(CGRect(x: 0, y: top, width: 1, height: rowHeight))
                }
                continue
            case .trailer:
                break
            }
            if unified, let blockIndex, let colors = palette.colors(for: layout.blocks[blockIndex]) {
                // The change's box continues through the gutter.
                let rows = geometry.rows.rows(ofBlock: blockIndex)
                context.setFillColor(host.isSelected(block: blockIndex) ? colors.selectedGutter : colors.border)
                if row == rows.lowerBound { context.fill(CGRect(x: 0, y: top, width: width, height: 1)) }
                if row == rows.upperBound - 1 {
                    context.fill(CGRect(x: 0, y: top + rowHeight - 1, width: width, height: 1))
                }
            }
            let numbers = geometry.rows.numbers(ofRow: row)
            let bold = row == caretRow
            let baseline = top + metrics.baseline
            func put(_ value: Int?, right: CGFloat) {
                guard let value else { return }
                let line = number(value, bold: bold, metrics: metrics)
                let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
                context.setFillColor(numberColor)
                context.textPosition = CGPoint(x: right - 8 - lineWidth, y: baseline)
                CTLineDraw(line, context)
            }
            if unified {
                put(numbers.a, right: columnWidth)
                put(numbers.b, right: width)
                if let letterSide {
                    context.setFillColor(numberColor)
                    context.setAlpha(0.7)
                    context.textPosition = CGPoint(x: (letterSide == .a ? 0 : columnWidth) + 5, y: baseline)
                    CTLineDraw(letter(letterSide, metrics: metrics), context)
                    context.setAlpha(1)
                }
            } else {
                put(side == .a ? numbers.a : numbers.b, right: width)
            }
        }
        if host.mode == .fluid { drawInsertionMarkers(context, host: host, geometry: geometry, offset: offset) }
        context.setFillColor(palette.gutterBorder)
        if unified {
            context.fill(CGRect(x: columnWidth - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height))
        }
        context.fill(CGRect(x: width - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height))
    }

    /// Fluid: the insertion line of a change empty on this side continues
    /// through the gutter.
    private func drawInsertionMarkers(_ context: CGContext, host: BlocksDiffView, geometry: PaneGeometry,
                                      offset: CGFloat) {
        guard let model = host.model else { return }
        let layout = model.layout
        let rows = geometry.rows(in: offset, offset + bounds.height)
        guard !rows.isEmpty else { return }
        let last = layout.blocks.count - 1
        let first = geometry.rows.block(atRow: rows.lowerBound) ?? last
        let end = geometry.rows.block(atRow: rows.upperBound - 1) ?? last
        guard first >= 0 else { return }
        for index in max(0, first - 1) ... min(last, end + 1) {
            let block = layout.blocks[index]
            let own = side == .a ? block.a : block.b
            guard own.isEmpty, let colors = host.palette.colors(for: block) else { continue }
            let y = geometry.y(ofRow: own.lowerBound) - offset
            context.setFillColor(host.isSelected(block: index) ? colors.selectedGutter : colors.border)
            context.fill(CGRect(x: 0, y: y - 0.5, width: bounds.width, height: 1))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let host, let geometry = host.geometry(for: side) else { return }
        let point = convert(event.locationInWindow, from: nil)
        host.selectChange(atRow: geometry.row(atY: point.y + host.scrollY(of: side)), pane: side)
    }
}

/// What sits between the two panes.
///
/// Blocks: a 2 pt divider that takes each difference's border colour beside
/// it (the change bar, and the inner edge of the padding boxes).
///
/// Fluid: a gutter that joins every visible difference's lines in A to its
/// lines in B with straight 1 pt connector lines, top edge to top edge and
/// bottom edge to bottom edge. A side without lines contributes a single
/// point, its insertion line.
@MainActor
final class DividerView: NSView, BlocksPart {
    weak var host: BlocksDiffView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let host, let context = NSGraphicsContext.current?.cgContext else { return }
        let palette = host.palette
        context.setFillColor(palette.background)
        context.fill(dirtyRect)
        if host.mode == .fluid {
            drawConnectors(context, host: host)
            return
        }
        // The divider colour may be translucent: lay it over the background.
        context.setFillColor(palette.divider)
        context.fill(dirtyRect)
        guard let model = host.model, let geometry = host.geometryA else { return }
        let offset = host.scrollY
        let layout = model.layout
        var row = max(0, geometry.row(atY: dirtyRect.minY + offset))
        let last = min(geometry.rows.count, geometry.row(atY: dirtyRect.maxY + offset) + 1)
        while row < last, let block = geometry.rows.block(atRow: row) {
            let rows = geometry.rows.rows(ofBlock: block)
            if let colors = palette.colors(for: layout.blocks[block]) {
                let top = geometry.y(ofRow: rows.lowerBound) - offset
                let bottom = geometry.y(ofRow: rows.upperBound) - offset
                context.setFillColor(host.isSelected(block: block) ? colors.selectedGutter : colors.border)
                context.fill(CGRect(x: 0, y: top, width: bounds.width, height: bottom - top))
            }
            row = rows.upperBound
        }
    }

    private func drawConnectors(_ context: CGContext, host: BlocksDiffView) {
        guard let model = host.model, let geometryA = host.geometryA, let geometryB = host.geometryB else { return }
        let layout = model.layout
        let offsetA = host.scrollY(of: .a), offsetB = host.scrollY(of: .b)
        let height = bounds.height, width = bounds.width
        let last = layout.blocks.count - 1
        guard last >= 0 else { return }
        func blockRange(_ geometry: PaneGeometry, _ offset: CGFloat) -> ClosedRange<Int> {
            let rows = geometry.rows(in: offset, offset + height)
            let first = rows.isEmpty ? last : geometry.rows.block(atRow: rows.lowerBound) ?? last
            let end = rows.isEmpty ? last : geometry.rows.block(atRow: rows.upperBound - 1) ?? last
            return max(0, first - 1) ... min(last, end + 1)
        }
        let rangeA = blockRange(geometryA, offsetA), rangeB = blockRange(geometryB, offsetB)
        let from = min(rangeA.lowerBound, rangeB.lowerBound), to = max(rangeA.upperBound, rangeB.upperBound)
        context.setLineWidth(1)
        context.setShouldAntialias(true)
        for index in from ... to {
            let block = layout.blocks[index]
            guard let colors = host.palette.colors(for: block) else { continue }
            let aTop = geometryA.y(ofRow: block.a.lowerBound) - offsetA
            let aBottom = geometryA.y(ofRow: block.a.upperBound) - offsetA
            let bTop = geometryB.y(ofRow: block.b.lowerBound) - offsetB
            let bBottom = geometryB.y(ofRow: block.b.upperBound) - offsetB
            if max(aBottom, bBottom) < -2 || min(aTop, bTop) > height + 2 { continue }
            let selected = host.isSelected(block: index)
            if selected {
                context.setFillColor(colors.selectedBand)
                let shape = CGMutablePath()
                shape.addLines(between: [CGPoint(x: 0, y: aTop), CGPoint(x: width, y: bTop),
                                         CGPoint(x: width, y: bBottom), CGPoint(x: 0, y: aBottom)])
                shape.closeSubpath()
                context.addPath(shape)
                context.fillPath()
            }
            context.setStrokeColor(selected ? colors.selectedGutter : colors.border)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: aTop + 0.5))
            path.addLine(to: CGPoint(x: width, y: bTop + 0.5))
            path.move(to: CGPoint(x: 0, y: aBottom - 0.5))
            path.addLine(to: CGPoint(x: width, y: bBottom - 0.5))
            // The A and B edges of the box, where the side has lines.
            if aBottom > aTop {
                path.move(to: CGPoint(x: 0.5, y: aTop))
                path.addLine(to: CGPoint(x: 0.5, y: aBottom))
            }
            if bBottom > bTop {
                path.move(to: CGPoint(x: width - 0.5, y: bTop))
                path.addLine(to: CGPoint(x: width - 0.5, y: bBottom))
            }
            context.addPath(path)
            context.strokePath()
        }
    }
}

/// The vertical scroller of the comparison. Its track doubles as an
/// overview of the document: a dot for every difference, at its place in
/// the document and in its colour, and a tick for every find match. Dots
/// that would overlap are merged.
@MainActor
final class OverviewScroller: NSScroller {
    struct Mark: Equatable {
        enum Kind { case insert, delete, change, match }
        /// Top and bottom as fractions of the document height.
        var top: CGFloat
        var bottom: CGFloat
        var kind: Kind
    }

    weak var host: BlocksDiffView?
    var marks: [Mark] = [] {
        didSet { if marks != oldValue { needsDisplay = true } }
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard let host, let context = NSGraphicsContext.current?.cgContext else {
            super.drawKnobSlot(in: slotRect, highlight: flag)
            return
        }
        let palette = host.palette
        context.setFillColor(palette.background)
        context.fill(slotRect)
        context.setFillColor(palette.gutterBorder)
        context.fill(CGRect(x: slotRect.minX, y: slotRect.minY, width: 1, height: slotRect.height))
        let track = slotRect.insetBy(dx: 3, dy: 2)
        guard track.height > 0 else { return }
        func y(_ fraction: CGFloat) -> CGFloat {
            isFlipped ? track.minY + fraction * track.height : track.maxY - fraction * track.height
        }
        var pending: (top: CGFloat, bottom: CGFloat, color: CGColor)?
        func flush() {
            guard let dot = pending else { return }
            let rect = CGRect(x: track.minX + 1, y: dot.top, width: track.width - 1, height: dot.bottom - dot.top)
            context.setFillColor(dot.color)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: min(2, rect.width / 2),
                                   cornerHeight: min(2, rect.height / 2), transform: nil))
            context.fillPath()
            pending = nil
        }
        for mark in marks where mark.kind != .match {
            let colors: ThemePalette.Difference = switch mark.kind {
            case .insert: palette.insert
            case .delete: palette.delete
            default: palette.change
            }
            var top = min(y(mark.top), y(mark.bottom)), bottom = max(y(mark.top), y(mark.bottom))
            if bottom - top < 3 {
                let middle = (top + bottom) / 2
                top = middle - 1.5
                bottom = middle + 1.5
            }
            if let dot = pending, top <= dot.bottom + 1 {
                pending = (dot.top, max(dot.bottom, bottom), dot.color)
            } else {
                flush()
                pending = (top, bottom, colors.border)
            }
        }
        flush()
        context.setFillColor(palette.findCurrent)
        for mark in marks where mark.kind == .match {
            let middle = y(mark.top)
            context.fill(CGRect(x: track.minX, y: middle - 1, width: track.width + 1, height: 2))
        }
    }
}
